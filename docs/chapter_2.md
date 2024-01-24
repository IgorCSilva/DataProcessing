# Long-Running Processes Using GenServer

GenServer, which is short for generic server, enables us to create concurrent processes that we can interact with.

## Starting with a Basic GenServer

Create the following file:
- in sender/lib/send_server.ex:
```elixir
defmodule SendServer do
  use GenServer
end
```

## Initializing the Process
The init/1 callback runs as soon as the process starts.

We are going to extend SendServer with the ability to send emails. If an email fails to send for whatever reason, we will also retry sending it, but we will limit the maximum number of retries.

- in sender/lib/send_server.ex:
```elixir
  def init(args) do
    IO.puts("Received arguments: #{inspect(args)}")
    max_retries = Keyword.get(args, :max_retries, 5)
    state = %{emails: [], max_retries: max_retries}
    {:ok, state}
  end
```

Execute in iex shell:
```sh
iex(2)> {:ok, pid} = GenServer.start(SendServer, [max_retries: 1])
Received arguments: [max_retries: 1]
{:ok, #PID<0.188.0>}
```

SendServer is now running in the background. There are several ways to stop a running process, as you will see later, but for now, let’s use GenServer.stop/3:

```sh
iex(3)> GenServer.stop(pid)
:ok
```

There are a number of result values supported by the init/1 callback. The most common ones are:
```elixir
{:ok, state}
{:ok, state, {:continue, term}}
:ignore
{:stop, reason}
```

We already used {:ok, state} . The extra option {:continue, term} is great for doing post-initialization work. You may be tempted to add complex logic to your init/1 function, such as fetching information from the database to populate the GenServer state, but that’s not desirable because the init/1 function is synchronous and should be quick. This is where {:continue, term} becomes really useful. If you return {:ok, state, {:continue, :fetch_from_database}} , the handle_continue/2 callback will be invoked after init/1 , so you can provide the following implementation:

```elixir
  def handle_continue(:fetch_from_database, state) do
    # called after init/1
  end
```

If the given configuration is not valid or something else prevents this process from continuing, we can return either :ignore or {:stop, reason} . The difference is that if the process is under a supervisor, {:stop, reason} will make the supervisor restart it, while :ignore won’t trigger a restart.

### Breaking Down Work in Multiple Steps
Rather than blocking the whole application from starting, we return {:ok, state, {:continue, term}} from the init/1 callback, and use handle_continue/2.

Accepted return values for handle_continue/2 include:
```elixir
{:noreply, new_state}
{:noreply, new_state, {:continue, term}}
{:stop, reason, new_state}
```

Since the callback receives the latest state, we can use it to update it with new
information by returning {:noreply, new_state}. For example:

```elixir
  def handle_continue(:fetch_from_database, state) do
    # get users from the database.
    {:noreply, Map.put(state, :users, users)}
  end
```

Although handle_continue/2 is often used in conjunction with init/1, other callbacks can also return {:continue, term}.

### Sending Process Messages

If you want to get some information back from the process, you use GenServer.call/3. When you don’t need a result back, you can use GenServer.cast/2. When the cast/2 and call/3 functions are used, the handle_cast/2 and handle_call/3 callbacks are invoked, respectively.

- in sender/lib/send_server.ex:
```elixir
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
```

By returning {reply, state, state} we send back the current state to the caller.

The most common return values from handle_call/3 are:
```elixir
{:reply, reply, new_state}
{:reply, reply, new_state, {:continue, term}}
{:stop, reason, reply, new_state}
```

Let's try it:
```sh
iex(1)> {:ok, pid} = GenServer.start(SendServer, [max_retries: 1])
Received arguments: [max_retries: 1]
{:ok, #PID<0.165.0>}
iex(2)> GenServer.call(pid, :get_state)
%{emails: [], max_retries: 1}
```

Let’s call the send_email/1 function from our handle_cast/2 callback.
- in sender/lib/send_server.ex:
```elixir
  def handle_cast({:send, email}, state) do
    Sender.send_email(email)
    emails = [%{email: email, status: "sent", retries: 0}] ++ state.emails

    {:noreply, %{state | emails: emails}}
  end
```

Restart iex shell and test handle_cast/2 function.

```sh
iex(1)> {:ok, pid} = GenServer.start(SendServer, [max_retries: 1])
Received arguments: [max_retries: 1]
{:ok, #PID<0.165.0>}
iex(2)> GenServer.cast(pid, {:send, "hello@email.com"})
:ok
Email to hello@email.com sent
iex(3)> GenServer.call(pid, :get_state)
%{
  emails: [%{email: "hello@email.com", retries: 0, status: "sent"}],
  max_retries: 1
}
```

### Notifying the Process of Events

You can also send a message to a process using Process.send/2 . This type of generic message will trigger the handle_info/2 callback. Normally, you will expose your server API using cast/2 and call/2, and keep send/2 for internal use.

- in sender/lib/sender.ex:
```elixir
  def send_email("konnichiwa@world.com" = email) do
    :error
  end

  def send_email(email) do
    Process.sleep(3000)
    IO.puts("Email to #{email} sent")
    {:ok, "email_sent"}
  end
```

- in sender/lib/send_server.ex:
```elixir

  def init(args) do
    IO.puts("Received arguments: #{inspect(args)}")
    max_retries = Keyword.get(args, :max_retries, 5)
    state = %{emails: [], max_retries: max_retries}

>>> Process.send_after(self(), :retry, 5000)
    {:ok, state}
  end


  def handle_cast({:send, email}, state) do
    status =
      case Sender.send_email(email) do
        {:ok, "email_sent"} -> "sent"
        :error -> "failed"
      end
      
    emails = [%{email: email, status: status, retries: 0}] ++ state.emails

    {:noreply, %{state | emails: emails}}
  end

  def handle_info(:retry, state) do
    {failed, done} =
      Enum.split_with(state.emails, fn item ->
        item.status == "failed" && item.retries < state.max_retries
      end)

    retried =
      Enum.map(failed, fn item ->
        IO.puts("Retrying email #{item.email}...")

        new_status =
          case Sender.send_email(item.email) do
            {:ok, "email_sent"} -> "sent"
            :error -> "failed"
          end

        %{email: item.email, status: new_status, retries: item.retries + 1}
      end)

    Process.send_after(self(), :retry, 5000)

    {:noreply, %{state | emails: retried ++ done}}
  end
```

Try this in iex.
```sh
iex(8)> {:ok, pid} = GenServer.start(SendServer, [max_retries: 2])
Received arguments: [max_retries: 2]
{:ok, #PID<0.220.0>}
iex(9)> GenServer.cast(pid, {:send, "konnichiwa@email.com"})
:ok
Email to konnichiwa@email.com sent
iex(10)> GenServer.cast(pid, {:send, "konnichiwa@world.com"})
:ok
Retrying email konnichiwa@world.com...
Retrying email konnichiwa@world.com...
iex(11)> GenServer.call(pid, :get_state)                           
%{
  emails: [
    %{email: "konnichiwa@world.com", retries: 2, status: "failed"},
    %{email: "konnichiwa@email.com", retries: 0, status: "sent"}
  ],
  max_retries: 2
}
```

### Process Teardown

The final callback in the list is terminate/2 . It is usually invoked before the process exits, but only when the process itself is responsible for the exit.

There are cases when a GenServer process is forced to exit due to an
external event, for example, when the whole application shuts
down. In those cases, terminate/2 will not be invoked by default.
This is something you have to keep in mind if you want to ensure
that important business logic always runs before the process exits.
For example, you may want to persist in-memory data (stored in the
process’s state) to the database before the process dies.

This is out of the scope of this book, but if you want to ensure that
terminate/2 is always called, look into setting Process.flag(:trap_exit, true) on the process, or use Process.monitor/1 to perform the required
work in a separate process.

Let’s implement terminate/2 by printing a message before the process exits:

- in sender/lib/send_server.ex:
```elixir
  def terminate(reason, _state) do
    IO.puts("Terminating with reason #{reason}")
  end
```

Now, recompile and use GenServer.stop/1.
```sh
iex(15)> {:ok, pid} = GenServer.start(SendServer, [])
Received arguments: []
{:ok, #PID<0.252.0>}
iex(16)> GenServer.stop(pid)                         
Terminating with reason normal
:ok
```

### Using the Task Module with GenServer
You can free up your GenServer process by using Task.start/1 and Task.async/2 to run code concurrently. Upon completion, the Task process will send messages back to GenServer , which you can process with handle_info/2 . For more information, see the documentation for Task.Supervisor.async_nolink/3 [22] which contains some useful examples.

## Building a Job-Processing System

Let’s scaffold a new Elixir project with a supervision tree.

`mix new jobber --sup`
`cd jobber`

Create the file for job implementation.
- in jobber/lib/jobber/job.ex:
```elixir
defmodule Jobber.Job do
  use GenServer
  require Logger

end
```

### Initializing the Job Process

- in jobber/lib/jobber/job.ex:
```elixir
defstruct [:work, :id, :max_retries, retries: 0, status: "new"]
  
  def init(args) do
    work = Keyword.fetch!(args, :work)
    id = Keyword.get(args, :id, random_job_id())
    max_retries = Keyword.get(args, :max_retries, 3)
    
    state = %Jobber.Job{id: id, work: work, max_retries: max_retries}
    
    {:ok, state, {:continue, :run}}
  end
  
  defp random_job_id() do
    :crypto.strong_rand_bytes(5)
    |> Base.url_decode64(padding: false)
  end
```

We must also add :crypto to the extra_applications list in mix.exs:

- in jobber/mix.exs:
```elixir
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Jobber.Application, []}
    ]
  end
```

Although the :crypto module is available to us, it is not part of the Erlang standard library, so it must be added to extra_applications when it is used.

### Performing Work

Implement the code to execute after the init.

- in :
```elixir
  def handle_continue(:run, state) do
    new_state = state.work.() |> handle_job_result(state)
    
    if new_state.status == "errored" do
      Process.send_after(self(), :retry, 5000)
      {:noreply, new_state}
    else
      Logger.info("Job exiting #{state.id}")
      {:stop, :normal, new_state}
    end
  end

  defp handle_job_result({:ok, data}, state) do
    Logger.info("Job completed #{state.id}")
    %Jobber.Job{state | status: "done"}
  end

  defp handle_job_result(:error, %{status: "new"} = state) do
    Logger.warn("Job errored #{state.id}")
    %Jobber.Job{state | status: "errored"}
  end

  defp handle_job_result(:error, %{status: "errored"} = state) do
    Logger.warn("Job retry failed #{state.id}")
    new_state = %Jobber.Job{state | retries: state.retries + 1}

    if new_state.retries == state.max_retries do
      %Jobber.Job{new_state | status: "failed"}
    else
      new_state
    end
  end

  def handle_info(:retry, state) do
    # Delegate work to the `handle_continue/2` callback.
    {:noreply, state, {:continue, :run}}
  end
```

Let's try all.
```sh
iex(3)> GenServer.start(Jobber.Job, work: fn -> Process.sleep(5000); {:ok, []} end)
{:ok, #PID<0.221.0>}
iex(4)> 
20:57:19.545 [info] Job completed NG1vPOc
 
20:57:19.545 [info] Job exiting NG1vPOc
```

Set the functions in variables:
```sh
iex(2)> good_job = fn ->
...(2)> Process.sleep(5000)
...(2)> {:ok, []}
...(2)> end

iex(3)> GenServer.start(Jobber.Job, work: good_job) 
```

To test the retry logic, we need a function that returns an :error.
```sh
iex(2)> bad_job = fn ->
...(2)> Process.sleep(5000)
...(2)> :error
...(2)> end

iex(3)> GenServer.start(Jobber.Job, work: bad_job)
{:ok, #PID<0.233.0>}
iex(4)> 
21:03:38.771 [warning] Job errored Y7kNmoU
 
21:03:48.773 [warning] Job retry failed Y7kNmoU
 
21:03:58.775 [warning] Job retry failed Y7kNmoU
 
21:04:08.777 [warning] Job retry failed Y7kNmoU
 
21:04:08.777 [info] Job exiting Y7kNmoU
```

## Introducing DynamicSupervisor

Dynamic Supervisor can start any GenServer process on demand.

Let’s add it to the supervision tree:
- in jobber/lib/jobber/application.ex:
```elixir
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Jobber.JobRunner}
    ]
```

The strategy setting is required, and the only strategy that is currently accepted is
:one_for_one.

- Module-Based DynamicSupervisor
You can also define a DynamicSupervisor module, like we do later in Implementing a Supervisor. Instead of use Supervisor you will need use DynamicSupervisor and call DynamicSupervisor.init/1 with the required :strategy value. You don’t have to provide a list of children processes.


Create .iex.exs at the top project directory with the following content.

- in jobber/.iex.exs:
```elixir
good_job = fn ->
  Process.sleep(5000)
  {:ok, []}
end

bad_job = fn ->
  Process.sleep(5000)
  :error
end
```

Now, a helper function for starting jobs.
- in jobber/lib/jobber.ex:
```elixir
defmodule Jobber do
  alias Jobber.{JobRunner, Job}

  def start_job(args) do
    DynamicSupervisor.start_child(JobRunner, {Job, args})
  end
end
```

DynamicSupervisor expects start_link/1 to be defined, and uses it to start the process and link it automatically.
- in jobber/lib/jobber/job.ex:
```elixir
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end
```

Let’s restart IEx and make sure everything works.
```sh
iex(4)> Jobber.start_job(work: good_job)
{:ok, #PID<0.212.0>}
iex(5)> 
16:52:07.154 [info] Job completed fP9MyHo
 
16:52:07.158 [info] Job exiting fP9MyHo
 
16:52:12.159 [info] Job completed 6YZc4dI
 
16:52:12.159 [info] Job exiting 6YZc4dI
 
16:52:17.160 [info] Job completed OXQViH0
 
16:52:17.160 [info] Job exiting OXQViH0
...
```

### Process Restart Values Revisited

By default, GenServer processes are always restarted by their supervisor, which is the :permanent setting. In our case, we intentionally shut down the process. However, JobRunner thinks something must have gone wrong, so it will keep restarting the process forever. We can easily fix this by using the :transient restart option, which tells the supervisor not to restart the process if it is exiting normally.

- in :
```elixir
  use GenServer, restart: :transient
```

Try again:
```sh
iex(1)> Jobber.start_job(work: good_job)
{:ok, #PID<0.169.0>}
iex(2)> 
16:59:41.908 [info] Job completed Mb-Lyfw
 
16:59:41.913 [info] Job exiting Mb-Lyfw
```

We fixed the issue successfully. Let’s try the bad_job test case.
```sh
iex(1)> Jobber.start_job(work: bad_job) 
{:ok, #PID<0.157.0>}
iex(2)> 
17:01:41.385 [warning] Job errored 8jaKw1s
 
17:01:51.391 [warning] Job retry failed 8jaKw1s
 
17:02:01.393 [warning] Job retry failed 8jaKw1s
 
17:02:11.395 [warning] Job retry failed 8jaKw1s
 
17:02:11.395 [info] Job exiting 8jaKw1s
```

Exit iex and code.
- in :
```elixir
doomed_job = fn ->
  Process.sleep(5000)
  raise "Boom!"
end
```

Now, give the doomed_job function to JobRunner.
```sh
iex(1)> Jobber.start_job(work: doomed_job)
{:ok, #PID<0.157.0>}
iex(2)> 
17:05:29.453 [error] GenServer #PID<0.157.0> terminating
** (RuntimeError) Boom!
    (stdlib 4.0) erl_eval.erl:742: :erl_eval.do_apply/7
    (jobber 0.1.0) lib/jobber/job.ex:27: Jobber.Job.handle_continue/2
    (stdlib 4.0) gen_server.erl:1120: :gen_server.try_dispatch/4
    (stdlib 4.0) gen_server.erl:862: :gen_server.loop/7
    (stdlib 4.0) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
Last message: {:continue, :run}
```

The process is stuck once gain. It seems to be continuously restarting by throwing the same exception over and over again.

### Adjusting Restart Frequency
A supervisor like JobRunner has two settings— max_restarts and max_seconds —that control something we call restart frequency. By default, max_restarts is set to 3 and max_seconds to 5. As a result, during a five-second time window, a supervisor will attempt to restart a process three times, before it gives up.

Let’s increase max_seconds to thirty seconds.
- in jobber/lib/jobber/application.ex:
```elixir
  job_runner_config = [
    strategy: :one_for_one,
    max_seconds: 30,
    name: Jobber.JobRunner
  ]
  children = [
    {DynamicSupervisor, job_runner_config}
  ]
```

Restart the iex and try:
```sh
iex(1)> Process.whereis(Jobber.JobRunner)
#PID<0.164.0>
iex(2)> Jobber.start_job(work: doomed_job)
{:ok, #PID<0.168.0>}
iex(3)> 
17:15:14.132 [error] GenServer #PID<0.168.0> terminating
** (RuntimeError) Boom!
-- rest of the error log omitted --

iex(3)> Process.whereis(Jobber.JobRunner) 
#PID<0.174.0>
```

You’ll see the error message above four times, because the process is restarted three times after the first exception. This may look like a success, but it’s too early to celebrate. Let’s check the PID for JobRunner again.

As you can see, there is a new process identifier for JobRunner , which means that the supervisor itself was restarted. If a :transient or :permanent restart option is used and a process keeps crashing, the supervisor will exit, because it has failed to restart that process and ensure the reliability of the system.

As a result of JobRunner exiting, any concurrent Job processes will be also terminated. Even if a single process fails to be recovered, it could endanger all other running processes. However, this can be easily fixed by adding a supervisor for each Job process, which will handle restarts and gracefully exit when its process fails.

## Implementing a Supervisor
Let’s start by creating the supervisor module. Since this is going to be a linked process, we’ll implement start_link/1 and init/1.
- in jobber/lib/jobber/job_supervisor.ex:
```elixir
defmodule Jobber.JobSupervisor do
  use Supervisor, restart: :temporary
  
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end
  
  def init(args) do
    children = [
      {Jobber.Job, args}
    ]
    
    options = [
      strategy: :one_for_one,
      max_seconds: 30
    ]
    
    Supervisor.init(children, options)
  end
end
```

Finally, let’s modify Jobber.start_job/1 to use JobSupervisor instead of running the Job process directly:
- in jobber/lib/jobber.ex:
```elixir
defmodule Jobber do
  alias Jobber.{JobRunner, JobSupervisor}

  def start_job(args) do
    DynamicSupervisor.start_child(JobRunner, {JobSupervisor, args})
  end
end
```

We can now start IEx and repeat our last experiment.
```sh
iex(1)> Process.whereis(Jobber.JobRunner)
#PID<0.171.0>
iex(2)> Jobber.start_job(work: doomed_job)
{:ok, #PID<0.175.0>}
iex(3)> 
17:39:11.819 [error] GenServer #PID<0.176.0> terminating
** (RuntimeError) Boom!
...
...
iex(3)> Process.whereis(Jobber.JobRunner) 
#PID<0.171.0>
```

## Naming Processes Using the Registry

Processes can be named when they start via the :name option, which is what we did when creating JobRunner.

```elixir
    job_runner_config = [
      strategy: :one_for_one,
      max_seconds: 30,
      name: Jobber.JobRunner
    ]
    children = [
      {DynamicSupervisor, job_runner_config}
    ]
```

There are three types of accepted values when naming a process:
- An atom, like :job_runner . This includes module names;
- A {:global, term} tuple, like {:global, :job_runner} , which registers the process globally. Useful for distributed applications;
- A {:via, module, term} tuple, where module is an Elixir module that would take care of the registration process, using the value term.

Using Elixir atoms may seem convenient, but could be a problem when starting many uniquely named process, like we do for jobber . Atoms are not garbage collected by the Erlang VM, and there are soft limits on how many atoms could be used in the system.

This is where the Elixir Registry comes in. It allows us to use strings, rather than atoms, which don’t have the same limitation and are generally much easier to work with. The Registry also comes with some helpers for looking up process by name and filtering the results, which are nice additions.

### Starting a Registry Process

Make the following change
- in jobber/lib/jobber/application.ex:
```elixir
    children = [
      {Registry, keys: :unique, name: Jobber.JobRegistry},
      {DynamicSupervisor, job_runner_config}
    ]
```

The keys are the names of the processes we are going to register. Using this setting, we can enforce all keys to be either :unique or allow duplicates with :duplicate.

You can restart IEx, and the JobRegistry process will be available for you to use.

### Registering New Process
First, let’s add a helper function.
- in :
```elixir
  def init(args) do
    work = Keyword.fetch!(args, :work)
>>> id = Keyword.get(args, :id)
    max_retries = Keyword.get(args, :max_retries, 3)

    state = %Jobber.Job{id: id, work: work, max_retries: max_retries}

    {:ok, state, {:continue, :run}}
  end

  def start_link(args) do
    args =
      if Keyword.has_key?(args, :id) do
        args
      else
        Keyword.put(args, :id, random_job_id())
      end
      
    id = Keyword.get(args, :id)
    type = Keyword.get(args, :type)
    
    GenServer.start_link(__MODULE__, args, name: via(id, type))
  end

  defp via(key, value) do
    {:via, Registry, {Jobber.JobRegistry, key, value}}
  end
```

This is all we need to register the process using JobRegistry . Now we can start using the data stored in the registry to put a limit on certain jobs.

### Querying the Registry

Let’s add a helper function to jobber.ex to retrieve all running processes labeled with import.

- in jobber/lib/jobber.ex:
```elixir
  def running_imports() do
    match_all = {:"$1", :"$2", :"$3"}
    guards = [{:"==", :"$3", "import"}]
    map_result = [%{id: :"$1", pid: :"$2", type: :"$3"}]
    
    Registry.select(Jobber.JobRegistry, [{match_all, guards, map_result}])
  end
```

- match_all is a wildcard that matches all entries in the registry.
- guards is a filter that filters results by the third element in the tuple, which has to be equal to "import".
- map_result is transforming the result by creating a list of maps, assigning each element of the tuple to a key, which makes the result a bit more readable.

Each value in the Registry is a tuple in the form of {name, pid, value} . In our case, name is the id , and value is the type label. Each element in the tuple is given a special identifier based on its position in the tuple. So :"$1" corresponds to the first element, which is the id , :"$2" is the pid , and so on. We use these as template variables to match, filter, and map entries in the Registry.

- in jobber/.iex.exs:
```elixir
good_job = fn ->
  Process.sleep(60_000)
  {:ok, []}
end
```

We will run three concurrent jobs, and two of them will be import jobs:

```sh
iex(6)> Jobber.start_job(work: good_job, type: "import")    
{:ok, #PID<0.194.0>}
iex(7)> Jobber.start_job(work: good_job, type: "send_email")
{:ok, #PID<0.197.0>}
iex(8)> Jobber.start_job(work: good_job, type: "import")    
{:ok, #PID<0.200.0>}
iex(9)> Jobber.running_imports()                            
[
  %{id: "PtCTdDM", pid: #PID<0.195.0>, type: "import"},
  %{id: "T6NmJqI", pid: #PID<0.201.0>, type: "import"}
]
```

OBS.: In the book, the result pids are equal to the pids returned by Jobber.start_job function.

### Limiting Concurrency of Import Jobs
- in jobber/lib/jobber.ex:
```elixir
  def start_job(args) do
    if Enum.count(running_imports()) >= 5 do
      {:error, :import_quota_reached}
    else
      DynamicSupervisor.start_child(JobRunner, {JobSupervisor, args})
    end
  end
```

Try starting more than five jobs. You will see the error.

You can use this project as a playground to continue practicing building fault-tolerant systems with GenServer and supervisors.

## Inspecting Supervisor at Runtime

When you have a supervision tree up and running, you may want to get some information from it at runtime. For example, how many processes are currently running under a particular supervisor, what kind of processes they are, and so on.

The first function is count_children/1  and is available in both DynamicSupervisor and Supervisor modules. When you call count_children/1 with a PID or a name of a supervisor process, you will get a map with the following keys and values:

- :supervisors - total number of supervisor child processes, both active and inactive;
- :workers - total number of worker (non-supervisor) child processes, both active and inactive;
- :specs - the total number of all child processes, both active and inactive;
- :active - the total number of actively running child processes.

Try it.
```sh
iex(1)> DynamicSupervisor.count_children(Jobber.JobRunner)
%{active: 0, specs: 0, supervisors: 0, workers: 0}
```

Let’s create a new job and wait for it to complete. Then, run count_children/1 again:
```sh
iex(2)> Jobber.start_job(work: good_job)
{:ok, #PID<0.173.0>}
iex(3)> 
11:18:48.055 [info] Job completed mD0OPp8
 
11:18:48.060 [info] Job exiting mD0OPp8
iex(3)> DynamicSupervisor.count_children(Jobber.JobRunner)
%{active: 1, specs: 1, supervisors: 1, workers: 0}
```

Now, count children while work is running.
```sh
iex(4)> Jobber.start_job(work: good_job)                  
{:ok, #PID<0.177.0>}
iex(5)> DynamicSupervisor.count_children(Jobber.JobRunner)
%{active: 2, specs: 2, supervisors: 2, workers: 0}
iex(6)> 
11:21:15.962 [info] Job completed ReMtY_s
 
11:21:15.962 [info] Job exiting ReMtY_s
```

We can get more information about running child processes by using which_children/1 . This function returns a list of tuples, and each tuple has four elements:

- The id of the child process, which could be :undefined for dynamically started processes;
- The PID of the child process or the value :restarting when the process is in the middle of a restart;
- The type of process, either :worker or :supervisor;
- The module implementation, which is returned in a list.

Just like count_children/1, which_children/1 is also implemented in the DynamicSupervisor and Supervisor modules.


Restart the iex.

Run:
```sh
iex(2)> Jobber.start_job(work: good_job)                  
{:ok, #PID<0.177.0>}
iex(3)> DynamicSupervisor.which_children(Jobber.JobRunner)
[{:undefined, #PID<0.160.0>, :supervisor, [Jobber.JobSupervisor]}]
```

This process is now running idle, since its only child process has exited successfully. We can verify this by using Supervisor.count_children/1 with the PID of the running JobSupervisor, like so:

```sh
iex(5)> children = DynamicSupervisor.which_children(Jobber.JobRunner)
[{:undefined, #PID<0.160.0>, :supervisor, [Jobber.JobSupervisor]}]
iex(6)> {_, pid, _, _} = List.first(children)
{:undefined, #PID<0.160.0>, :supervisor, [Jobber.JobSupervisor]}
iex(7)> Supervisor.count_children(pid)
%{active: 0, specs: 1, supervisors: 0, workers: 1}
```

As you have learned already, processes are lightweight, and idle processes like JobSupervisor are unlikely to cause any issues. However, thanks to which_children/1 and count_children/1 , you can easily find those processes and stop them if you wish. You can stop a supervisor using Supervisor.stop/1:

```sh
iex(8)> Supervisor.stop(pid)
:ok
iex(9)> DynamicSupervisor.which_children(Jobber.JobRunner)           
[]
```