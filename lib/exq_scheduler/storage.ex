defmodule ExqScheduler.Storage do
  @moduledoc false
  @schedules_key "schedules"
  @schedule_states_key "states"
  @schedule_prev_times_key "last_times"
  @schedule_next_times_key "next_times"
  @schedule_first_runs_key "first_runs"
  @schedule_last_runs_key "last_runs"
  @default_queue "default"

  defmodule Opts do
    @moduledoc false
    @enforce_keys [:namespace, :exq_namespace, :redis]
    defstruct @enforce_keys

    def new(opts) do
      %__MODULE__{
        namespace: opts[:namespace],
        exq_namespace: opts[:exq_namespace],
        redis: opts[:redis_pid]
      }
    end
  end

  alias ExqScheduler.Schedule
  alias ExqScheduler.Schedule.Parser
  alias ExqScheduler.Storage.Redis
  alias ExqScheduler.Storage
  alias ExqScheduler.Time
  alias Exq.Support.Job

  def persist_schedule(schedule_props, storage_opts) do
    {name, desc, cron, job, opts} = schedule_props
    schedule = Schedule.new(name, desc, cron, job, opts)

    val = Schedule.encode(schedule)
    _ = Redis.hset(storage_opts.redis, build_schedules_key(storage_opts), name, val)

    schedule_state =
      %{enabled: Map.get(opts, "enabled", true)}
      |> Poison.encode!()

    Redis.hset(
      storage_opts.redis,
      build_schedule_states_key(storage_opts),
      name,
      schedule_state
    )
  end

  def build_opts(env) do
    Keyword.get(env, :storage_opts)
    |> Keyword.put(:redis_pid, ExqScheduler.redis_name(env))
    |> Storage.Opts.new()
  end

  def persist_schedule_times(schedules, storage_opts) do
    Enum.each(schedules, fn schedule ->
      prev_times = Schedule.get_previous_run_dates(schedule.cron, schedule.tz_offset)

      if not Enum.empty?(prev_times) do
        prev_time =
          Enum.at(prev_times, 0)
          |> Timex.add(schedule.tz_offset)
          |> Poison.encode!()

        Redis.hset(
          storage_opts.redis,
          build_schedule_times_key(storage_opts, :prev),
          schedule.name,
          prev_time
        )
      end

      next_times = Schedule.get_next_run_dates(schedule.cron, schedule.tz_offset)

      if not Enum.empty?(next_times) do
        next_time =
          Enum.at(next_times, 0)
          |> Timex.add(schedule.tz_offset)
          |> Poison.encode!()

        Redis.hset(
          storage_opts.redis,
          build_schedule_times_key(storage_opts, :next),
          schedule.name,
          next_time
        )
      end

      now = Time.now() |> Timex.to_naive_datetime() |> Poison.encode!()

      schedule_first_run = get_schedule_first_run_time(storage_opts, schedule)

      if schedule_first_run == nil do
        Redis.hset(
          storage_opts.redis,
          build_schedule_runs_key(storage_opts, :first),
          schedule.name,
          now
        )
      end

      Redis.hset(
        storage_opts.redis,
        build_schedule_runs_key(storage_opts, :last),
        schedule.name,
        now
      )
    end)
  end

  def load_schedules_config(storage_opts, env, persist \\ true) do
    schedule_conf_list = Keyword.get(env, :schedules)

    if is_nil(schedule_conf_list) or Enum.empty?(schedule_conf_list) do
      []
    else
      Enum.map(schedule_conf_list, fn {name, schedule_conf} ->
        {description, cron, job, opts} = ExqScheduler.Schedule.Parser.get_schedule(schedule_conf)

        if persist do
          schedule_props = {name, description, cron, job, opts}
          persist_schedule(schedule_props, storage_opts)
        end

        Schedule.new(name, description, cron, job, opts)
      end)
    end
  end

  def get_schedule_last_run_time(storage_opts, schedule) do
    Redis.hget(
      storage_opts.redis,
      build_schedule_runs_key(storage_opts, :last),
      schedule.name
    )
  end

  def get_schedule_first_run_time(storage_opts, schedule) do
    Redis.hget(
      storage_opts.redis,
      build_schedule_runs_key(storage_opts, :first),
      schedule.name
    )
  end

  def is_schedule_enabled?(storage_opts, schedule) do
    schedule_state =
      Redis.hget(
        storage_opts.redis,
        build_schedule_states_key(storage_opts),
        schedule.name
      )

    if schedule_state != nil do
      Map.fetch!(schedule_state, "enabled")
    else
      # By default the schedule will always be enabled, so we return true
      # if the entry does not exist.
      true
    end
  end

  def get_schedules(storage_opts) do
    schedules_key = build_schedules_key(storage_opts)
    keys = Redis.hkeys(storage_opts.redis, schedules_key)

    Enum.map(keys, fn name ->
      {description, cron, job, opts} =
        Redis.hget(storage_opts.redis, schedules_key, name)
        |> Parser.get_schedule()

      Schedule.new(name, description, cron, job, opts)
    end)
  end

  def filter_active_jobs(storage_opts, schedules, time_range) do
    Enum.filter(schedules, fn schedule ->
      Storage.is_schedule_enabled?(storage_opts, schedule)
    end)
    |> Enum.map(fn schedule ->
      jobs = Schedule.get_jobs(storage_opts, schedule, time_range)
      {schedule, jobs}
    end)
  end

  def enqueue_jobs(schedule, jobs, storage_opts) do
    Enum.each(jobs, &enqueue_job(schedule, &1, storage_opts))
  end

  def queue_key(queue_name, storage_opts) do
    [storage_opts.exq_namespace, "queue", queue_name]
    |> build_key
  end

  # TODO: Update schedule.first_run, schedule.last_run
  defp enqueue_job(schedule, scheduled_job, storage_opts) do
    {job, time} = {scheduled_job.job, scheduled_job.time}

    job =
      if schedule.schedule_opts.include_metadata do
        metadata = %{scheduled_at: time}
        args = job.args

        args =
          cond do
            is_list(args) -> List.insert_at(args, -1, metadata)
            is_nil(args) -> [metadata]
            true -> args
          end

        %Job{job | args: args}
      else
        job
      end

    queue_name = job.queue || @default_queue

    commands = [
      ["SADD", queues_key(storage_opts), queue_name],
      ["LPUSH", queue_key(queue_name, storage_opts), Job.encode(job)]
    ]

    enqueue_key = build_enqueued_jobs_key(storage_opts)
    persist_schedule_times([schedule], storage_opts)
    Redis.cas(storage_opts.redis, build_lock_key(job, time, enqueue_key), commands)
  end

  defp build_lock_key(job, time, enqueue_key) do
    serialized_job = Job.encode(job)
    time_string = NaiveDateTime.to_string(time)

    [enqueue_key, serialized_job, time_string]
    |> build_key
  end

  defp queues_key(storage_opts) do
    [storage_opts.exq_namespace, "queues"]
    |> build_key
  end

  defp build_enqueued_jobs_key(storage_opts) do
    [storage_opts.exq_namespace, "enqueued_jobs"]
    |> build_key
  end

  defp build_schedules_key(storage_opts) do
    [storage_opts.exq_namespace, @schedules_key]
    |> build_key
  end

  defp build_schedule_states_key(storage_opts) do
    [storage_opts.namespace, @schedule_states_key]
    |> build_key
  end

  defp build_schedule_times_key(storage_opts, :prev) do
    [storage_opts.namespace, @schedule_prev_times_key]
    |> build_key
  end

  defp build_schedule_times_key(storage_opts, :next) do
    [storage_opts.namespace, @schedule_next_times_key]
    |> build_key
  end

  defp build_schedule_runs_key(storage_opts, :first) do
    [storage_opts.namespace, @schedule_first_runs_key]
    |> build_key
  end

  defp build_schedule_runs_key(storage_opts, :last) do
    [storage_opts.namespace, @schedule_last_runs_key]
    |> build_key
  end

  defp build_key(list) do
    list
    |> Enum.filter(&(!!&1))
    |> Enum.join(":")
  end
end
