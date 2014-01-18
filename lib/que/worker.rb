module Que
  class Worker
    attr_reader :thread

    def initialize(options)
      @job_queue    = options[:job_queue]
      @result_queue = options[:result_queue]
      @thread       = Thread.new { work_loop }
    end

    private

    def work_loop
      loop do
        begin
          # There's an edge case to be aware of - if we retrieve the job in
          # the same query where we take the advisory lock on it, there's a
          # race condition where we may lock a job that's already been worked,
          # if the query took its MVCC snapshot while the job was being
          # processed by another worker, but didn't attempt the advisory lock
          # until it was finished by that worker. Since we have the lock, a
          # previous worker would have deleted it by now, so we just retrieve
          # it now. If it doesn't exist, no problem, it was already worked.
          # Just saying, this is why we don't combine the 'get_job' query with
          # taking the advisory lock in Listener's work loop.
          pk = @job_queue.shift

          if job = Que.execute(:get_job, pk.values_at(:queue, :priority, :run_at, :job_id)).first
            klass = Job.class_for(job[:job_class])
            klass.new(job)._run
          end
        rescue => error
          begin
            count    = job[:error_count].to_i + 1
            interval = (klass.retry_interval if klass) || Job.retry_interval
            delay    = interval.respond_to?(:call) ? interval.call(count) : interval
            message  = "#{error.message}\n#{error.backtrace.join("\n")}"
            Que.execute :set_error, [count, delay, message] + job.values_at(:queue, :priority, :run_at, :job_id)
          rescue
            # If we can't reach the database for some reason, too bad, but
            # don't let it crash the work loop.
          end

          if Que.error_handler
            # Don't let a problem with the error handler crash the work loop.
            Que.error_handler.call(error) rescue nil
          end
        ensure
          @result_queue.push pk[:job_id].to_i
        end
      end
    end
  end
end
