# frozen_string_literal: true

require 'spec_helper'

describe "The job polling query" do
  def poll(count, options = {})
    queue_name = options[:queue_name] || ''
    job_ids = options[:job_ids] || []

    jobs = Que.execute :poll_jobs, [queue_name, "{#{job_ids.join(',')}}", count]

    returned_job_ids = jobs.map { |j| j[:id] }

    ids =
      Que.execute <<-SQL
        SELECT objid
        FROM pg_locks
        WHERE locktype = 'advisory'
        AND pid = pg_backend_pid()
      SQL

    ids.map!{|h| h[:objid].to_i}.sort

    assert_equal ids.sort, returned_job_ids.sort

    returned_job_ids
  end

  after do
    Que.execute "SELECT pg_advisory_unlock_all()"
  end

  it "should not fail if there aren't enough jobs to return" do
    id = Que::Job.enqueue.que_attrs[:id]
    assert_equal [id], poll(5)
  end

  it "should return only the requested number of jobs" do
    ids = 5.times.map { Que::Job.enqueue.que_attrs[:id] }
    assert_equal ids[0..3], poll(4)
  end

  it "should skip jobs with the given ids" do
    one = Que::Job.enqueue.que_attrs[:id]
    two = Que::Job.enqueue.que_attrs[:id]

    assert_equal [two], poll(2, job_ids: [one])
  end

  it "should skip jobs in the wrong queue" do
    one = Que::Job.enqueue(queue: 'one').que_attrs[:id]
    two = Que::Job.enqueue(queue: 'two').que_attrs[:id]

    assert_equal [one], poll(5, queue_name: 'one')
  end

  it "should only work a job whose scheduled time to run has passed" do
    future1 = Que::Job.enqueue(run_at: Time.now + 30).que_attrs[:id]
    past    = Que::Job.enqueue(run_at: Time.now - 30).que_attrs[:id]
    future2 = Que::Job.enqueue(run_at: Time.now + 30).que_attrs[:id]

    assert_equal [past], poll(5)
  end

  it "should prefer a job with lower priority" do
    # 1 is highest priority.
    [5, 4, 3, 2, 1, 2, 3, 4, 5].map { |p| Que::Job.enqueue priority: p }

    assert_equal jobs.where{priority <= 3}.select_order_map(:id), poll(5).sort
  end

  it "should prefer a job that was scheduled to run longer ago" do
    id1 = Que::Job.enqueue(run_at: Time.now - 30).que_attrs[:id]
    id2 = Que::Job.enqueue(run_at: Time.now - 60).que_attrs[:id]
    id3 = Que::Job.enqueue(run_at: Time.now - 30).que_attrs[:id]

    assert_equal [id2], poll(1)
  end

  it "should prefer a job that was queued earlier" do
    run_at = Time.now - 30
    id1 = Que::Job.enqueue(run_at: run_at).que_attrs[:id]
    id2 = Que::Job.enqueue(run_at: run_at).que_attrs[:id]
    id3 = Que::Job.enqueue(run_at: run_at).que_attrs[:id]

    first, second, third = jobs.select_order_map(:id)

    assert_equal [id1, id2], poll(2)
  end

  it "should skip jobs that are advisory-locked" do
    id1 = Que::Job.enqueue.que_attrs[:id]
    id2 = Que::Job.enqueue.que_attrs[:id]
    id3 = Que::Job.enqueue.que_attrs[:id]

    begin
      DB.get{pg_advisory_lock(id2)}

      assert_equal [id1, id3], poll(5)
    ensure
      DB.get{pg_advisory_unlock(id2)}
    end
  end

  it "should behave when being run concurrently by several connections" do
    q1, q2, q3, q4 = Queue.new, Queue.new, Queue.new, Queue.new

    threads = 4.times.map do
      Thread.new do
        Que.checkout do
          q1.push nil
          q2.pop

          Thread.current[:jobs] = poll(25)

          q3.push nil
          q4.pop

          Que.execute "SELECT pg_advisory_unlock_all()"
        end
      end
    end

    4.times { q1.pop }

    Que.execute <<-SQL
      INSERT INTO que_jobs (job_class, priority)
      SELECT 'Que::Job', 1
      FROM generate_series(1, 100) AS i;
    SQL

    job_ids = jobs.select_order_map(:id)
    assert_equal 100, job_ids.count

    4.times { q2.push nil }
    4.times { q3.pop }

    assert_equal job_ids, threads.map{|t| t[:jobs]}.flatten.sort

    4.times { q4.push nil }
    threads.each(&:join)
  end
end
