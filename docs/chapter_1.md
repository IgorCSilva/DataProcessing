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

### Startnig Processes
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