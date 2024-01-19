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
