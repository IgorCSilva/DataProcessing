# Easy Concurrency with the Task Module

## Introducing the Task Module
Elixir provides a low-level function and macro for concurrency - `spawn/1` and `receive`.

Elixir also ships with a module called `Task`, which significantly simplifies starting concurrent processes.

## Creating Our Playground
We are going to create an application called sender and pretend that we are sending emails to real email addresses.

Create project:
`mix new sender --sup`

- The `--sup` argument enable to create an application with a supervision tree.

Inside the sender folder, run:
`iex -S mix`

When some update is made, run recompile/0 function, like this:
`iex(1) recompile()`

Let’s open sender.ex and add the following:
- in sender/lib/sender.ex:
```elixir
  def send_email(email) do
    Process.sleep(3000)
    IO.puts("Email to #{email} sent")
    {:ok, "email_sent"}
  end
```

## Starting Tasks and Retrieving Results
Run:
```sh
iex> Sender.send_email("hello@world.com")
```

We had to wait three seconds until we saw the printed output and result.

Let’s add another function, notify_all/1:
- in sender/lib/sender.ex:
```elixir
  def notify_all(emails) do
    Enum.each(emails, &send_email/1)
  end
```

Create a file .iex.exs in the main project folder sender at the top level where mix.exs is also located. Add the following:
- in sender/.iex.exs:
```elixir
emails = [
  "hello@world.com",
  "hola@world.com",
  "nihao@world.com",
  "konnichiwa@world.com",
]
```

Once you save the file, quit IEx and start it again with `iex -S mix` . Type emails and press enter to inspect the variable:

```sh
iex> emails
```

Now let’s use the test data with notify_all/1.

```sh
iex> Sender.notify_all(emails)
```

It took four calls to send_email/1 and about twelve seconds to complete.

### Starting Processes
The Task module contains a number of very useful functions for running code asynchronously and concurrently. One of them is start/1.

```sh
iex> Task.start(fn -> IO.puts("Hello async world!") end)
Hello async world!
{:ok, #PID<0.166.0>}
```

Let's use Task.start in send_email/1. Modify the file.
- in sender/lib/sender.ex:
```elixir
  def notify_all(emails) do
    Enum.each(emails, fn email ->
      Task.start(fn ->
        send_email(email)
      end)
    end)
  end
```

Recompile and run notify_all/1.
```sh
iex> recompile()
iex> Sender.notify_all(emails)
```

This should be significantly faster—in fact, four times faster! All functions were called concurrently and finished at the same time, printing the success message as we expected.

### Retrieving the Result of a Task
To retrieve the result of a function, you have to use Task.async/1. It returns a %Task{} struct.

Let's try it.
```sh
iex> task = Task.async(fn -> Sender.send_email("hello@world.com") end)
%Task{
  mfa: {:erlang, :apply, 2},
  owner: #PID<0.162.0>,
  pid: #PID<0.196.0>,
  ref: #Reference<0.2197473363.1783431171.200667>
}
```

- owner: is the PID of the process that started the Task process.
- pid: is the identifier of the Task process itself.
- ref: is the process monitor reference.

To retrieve the result of the task, you can use either Task.await/1 or Task.yield/1 which accept a Task struct as an argument. There is an important difference in the way await/1 and yield/1 work, so you have to choose wisely. They both stop the program and try to retrieve the result of the task. The difference comes from the way they handle process `timeouts`.

Let’s increase the time the send_email/1 function takes to 30 seconds, just temporarily.

- in sender/lib/sender.ex:
```elixir
  def send_email(email) do
    Process.sleep(30000)
    IO.puts("Email to #{email} sent")
    {:ok, "email_sent"}
  end
```

Recompile and run Task.async with Task.await.
```sh
iex> recompile()
iex> Task.async(fn -> Sender.send_email("hi@world.com") end) |> Task.await()
** (exit) exited in: Task.await(%Task{mfa: {:erlang, :apply, 2}, owner: #PID<0.162.0>, pid: #PID<0.165.0>, ref: #Reference<0.2629191862.177012737.141972>}, 5000)
    ** (EXIT) time out
    (elixir 1.14.0) lib/task.ex:830: Task.await/2
```

When using await/1 we expect a task to finish within a certain amount of time. By default, this time is set to 5000ms, which is five seconds. You can change that by passing an integer with the amount of milliseconds as a second argument, for example Task.await(task, 10_000) . You can also disable the timeout by passing the atom :infinity.

In comparison, Task.yield/1 simply returns nil if the task hasn’t completed. The timeout of yield/1 is also 5000ms but does not cause an exception and crash. You can also do Task.yield(task) repeatedly to check for a result, which is not allowed by await/1 . A completed task will return either {:ok, result} or {:exit, reason} . You can see this in action:

```sh
iex> task = Task.async(fn -> Sender.send_email("hi@world.com") end)
%Task{
  mfa: {:erlang, :apply, 2},
  owner: #PID<0.162.0>,
  pid: #PID<0.170.0>,
  ref: #Reference<0.2629191862.177012737.142034>
}

iex> Task.yield(task)
nil

iex> Task.yield(task)
Email to hi@world.com sent
{:ok, {:ok, "email_sent"}}

iex> Task.yield(task)
nil
```

You can also use yield/2 and provide your own timeout, similarly to await/2 , but the :infinity option is not allowed.

While await/1 takes care of stopping the task, yield/1 will leave it running. It is a good idea to stop the task manually by calling Task.shutdown(task) . The shutdown/1 function also accepts a timeout and gives the process a last chance to complete, before stopping it. If it completes, you will receive the result as normal. You can also stop a process immediately (and rather violently) by using the atom :brutal_kill as a second argument.

Now, make the changes:
- in sender/lib/sender.ex:
```elixir
  def send_email(email) do
    Process.sleep(3000)
    IO.puts("Email to #{email} sent")
    {:ok, "email_sent"}
  end

  def notify_all(emails) do
    emails
    |> Enum.map(fn email ->
      Task.async(fn ->
        send_email(email)
      end)
    end)
    |> Enum.map(&Task.await/1)
  end
```

Let’s try out the latest changes.

```sh
iex> Sender.notify_all(emails)
Email to hello@world.com sent
Email to hola@world.com sent
Email to nihao@world.com sent
Email to konnichiwa@world.com sent
[ok: "email_sent", ok: "email_sent", ok: "email_sent", ok: "email_sent"]
```

tasks from lists of items is actually very common in Elixir. In the next section, we are going to use a function specifically designed for doing this. It also offers a range of additional features, especially useful when working with large lists.

## Managing Series of Tasks
Task module has a function `async_stream/3`. It works just like Enum.map/2 and Task.async/2 combined, with one major difference: you can set a limit on the number of processes running at the same time.

Execute the following code:
```sh
iex> Task.async_stream(emails, &Sender.send_email/1)
#Function<3.3144039/2 in Task.build_stream/3>
```

Instead of the usual result, we received a function, which is going to create a Stream.

Run the following:
```sh
iex> Stream.map([1, 2, 3], & &1 * 2)
#Stream<[
  enum: [1, 2, 3],
  funs: [#Function<48.6935098/1 in Stream.map/2>]
]>
```

Now, let’s update notify_all/1 to use async_stream/3 . This time, however, we will run the stream using Enum.to_list/1.

- in sender/lib/sender.ex:
```elixir
  def notify_all(emails) do
    emails
    |> Task.async_stream(&send_email/1)
    |> Enum.to_list()
  end
```

Recompile and test:
```sh
iex> recompile
Compiling 1 file (.ex)
:ok
iex> Sender.notify_all(emails)
Email to hello@world.com sent
Email to hola@world.com sent
Email to nihao@world.com sent
Email to konnichiwa@world.com sent
[
  ok: {:ok, "email_sent"},
  ok: {:ok, "email_sent"},
  ok: {:ok, "email_sent"},
  ok: {:ok, "email_sent"}
]
```

As we mentioned before, async_stream/3 maintains a limit on how many processes can be running at the same time. By default, this limit is set to the number of logical cores available in the system.

Make the update:
```elixir
  def notify_all(emails) do
    emails
    |> Task.async_stream(&send_email/1, max_concurrency: 1)
    |> Enum.to_list()
  end
```

You will see that emails are sent out one by one.
Revert the change.

Another option that needs mentioning is :ordered . Currently, async_stream/3 assumes we want the results in the same order as they were originally. This order preservation can potentially slow down our processing, because async_stream/3 will wait for a slow process to complete before moving on to the next.

We can potentially speed things up by disabling ordering like so:

```sh
|> Task.async_stream(&send_email/1, ordered: false)
```

Now async_stream/3 won’t be idle if one process is taking longer than others.

The :timeout optional parameter is supported and defaults to 5000ms. When a task reaches the timeout, it will produce an exception, stopping the stream and crashing the current process. This behavior can be changed using an optional :on_timeout argument, which you can set to :kill_task. This argument is similar to the :brutal_kill one supported by Task.shutdown/2.

```sh
|> Task.async_stream(&send_email/1, on_timeout: :kill_task)
```

As a result of using the :kill_task option, when a process exits with a timeout, async_stream/3 will ignore it and carry on as normal.

A process can crash for many reasons. Sometimes it is an unexpected error that causes an exception. The important thing is that when a process crashes, it can also crash the process that started it, which in turn crashes its parent process, triggering a chain reaction that can ultimately crash your whole application.

Elixir, thanks to Erlang, has a set of powerful tools to manage processes, catch crashes, and recover quickly. We will see in the next section.

## Linking Processes

Processes in Elixir can be linked together, and Task processes are usually automatically linked to the process that started them.

You can isolate crashes by configuring a process to trap exits. Trapping an exit means acknowledging the exit message of a linked process, but continuing to run instead of terminating.

You can configure a process to trap exits
manually, but usually you want to use a special type of process called a supervisor.

When we used async/1 and async_stream/3 , a process link was created for each new process. Task.start/1 , on the other hand, does not create a process link, but there is Task.start_link/1 that does just that.

Most functions in the Task module that link to the current process by default have an alternative, usually ending with _nolink . Task.Supervisor.async_nolink/3 is the alternative to Task.async/1 . Task.async_stream/3 can be replaced with Task.Supervisor.async_stream_nolink/4 . All functions in the Task.Supervisor module are designed to be linked to a supervisor.

## Meeting the Supervisor

Supervised processes are called child processes.
Our sender application already has a supervisor in place, which you can see in `sender/lib/sender/application.ex`.

At the end of the function we have Supervisor.start_link(children, opts) that starts the main supervisor of the application. Since the children variable is just an empty list, there are actually no child processes to supervise. This setup is the result of us using the --sup argument when calling the mix new command to create our project.

## Adding a Supervisor

- in sender/lib/sender/application.ex:
```elixir
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Sender.EmailTaskSupervisor}
    ]
    
    opts = [strategy: :one_for_one, name: Sender.Supervisor]
    Supervisor.start_link(children, opts)
  end
```

or
```elixir
  def start(_type, _args) do
    children = [
      %{
        id: Sender.EmailTaskSupervisor,
        start: {
          Task.Supervisor,
          :start_link,
          [[name: Sender.EmailTaskSupervisor]]
        }
      }
    ]
    
    opts = [strategy: :one_for_one, name: Sender.Supervisor]
    Supervisor.start_link(children, opts)
  end
```

## Using Task.Supervisor
Let’s see what happens when an error occurs and there is no supervisor in place.

- in :
```elixir
  def send_email("konnichiwa@world.com" = email) do
    raise "Oops, couldn't send email to #{email}!"
  end
  
  def send_email(email) do
    Process.sleep(3000)
    IO.puts("Email to #{email} sent")
    {:ok, "email_sent"}
  end
```

Execute:
```sh
iex> self()
#PID<0.169.0>
```

Now run the notify_all/1 funcion.
```sh
iex> Sender.notify_all(emails)

20:18:38.321 [error] Task #PID<0.176.0> started from #PID<0.169.0> terminating
** (RuntimeError) Oops, couldn't send email to konnichiwa@world.com!
    (sender 0.1.0) lib/sender.ex:7: Sender.send_email/1
    (elixir 1.14.0) lib/task/supervised.ex:89: Task.Supervised.invoke_mfa/2
    (elixir 1.14.0) lib/task/supervised.ex:34: Task.Supervised.reply/4
    (stdlib 4.0) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
Function: &:erlang.apply/2
    Args: [#Function<0.62202481/1 in Sender.send_email>, ["konnichiwa@world.com"]]
** (EXIT from #PID<0.169.0>) shell process exited with reason: an exception was raised:
    ** (RuntimeError) Oops, couldn't send email to konnichiwa@world.com!
        (sender 0.1.0) lib/sender.ex:7: Sender.send_email/1
        (elixir 1.14.0) lib/task/supervised.ex:89: Task.Supervised.invoke_mfa/2
        (elixir 1.14.0) lib/task/supervised.ex:34: Task.Supervised.reply/4
        (stdlib 4.0) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
```

Because of the link, created by async_stream/3 , IEx also crashed with the same exception message. You can verify this by running self() again. You will see a different PID.

Change notify_all/1 to use Task.Supervisor.async_stream_nolink/4 instead of Task.async_stream/3.

- in sender/lib/sender.ex:
```elixir
  def notify_all(emails) do
    Sender.EmailTaskSupervisor
    |> Task.Supervisor.async_stream_nolink(emails, &send_email/1)
    |> Enum.to_list()
  end
```

Recompile and run again.
```sh
iex(2)> recompile
Compiling 1 file (.ex)
:ok
iex(3)> Sender.notify_all(emails)

20:26:05.523 [error] Task #PID<0.206.0> started from #PID<0.177.0> terminating
** (RuntimeError) Oops, couldn't send email to konnichiwa@world.com!
    (sender 0.1.0) lib/sender.ex:7: Sender.send_email/1
    (elixir 1.14.0) lib/task/supervised.ex:89: Task.Supervised.invoke_mfa/2
    (elixir 1.14.0) lib/task/supervised.ex:34: Task.Supervised.reply/4
    (stdlib 4.0) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
Function: &:erlang.apply/2
    Args: [#Function<0.131357707/1 in Sender.send_email>, ["konnichiwa@world.com"]]
    
Email to hello@world.com sent
Email to hola@world.com sent
Email to nihao@world.com sent
[
  ok: {:ok, "email_sent"},
  ok: {:ok, "email_sent"},
  ok: {:ok, "email_sent"},
  exit: {%RuntimeError{
     message: "Oops, couldn't send email to konnichiwa@world.com!"
   },
   [
     {Sender, :send_email, 1,
      [file: 'lib/sender.ex', line: 7, error_info: %{module: Exception}]},
     {Task.Supervised, :invoke_mfa, 2,
      [file: 'lib/task/supervised.ex', line: 89]},
     {Task.Supervised, :reply, 4, [file: 'lib/task/supervised.ex', line: 34]},
     {:proc_lib, :init_p_do_apply, 3, [file: 'proc_lib.erl', line: 240]}
   ]}
]
```

If you run self() now, you will see that PID is the same before the crash. The crash was isolated.

## Understanding Let It Crash

We saw that supervisors can isolate crashes, but they can also restart child processes. There are three different restart values available to us:

- :temporary: will never restart child processes;
- :transient: will restart child processes but only when they exit with an error;
- :permanent: always restarts children, keeping them running, even when they try to shut down without an error.

If a :transient or :permanent restart value is used and a process keeps crashing, the supervisor will exit, because it has failed to restart that process.