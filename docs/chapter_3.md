# Data-Processing Pipelines with GenStage

We have a finite amount of memory and CPU power available. This means that our server may become overwhelmed by the amount of work it needs to do and become slow or unresponsive. Often we rely on third-party API services, which have rate limiting in place and fixed quotas for the number of requests we can make. If we go over their quota, requests will be blocked and our application will stop working as expected.

In this chapter, we’re going to learn how to build data-processing pipelines that can utilize our system resources reliably and effectively.

## Introducing GenStage

The GenStage behaviour, as its name suggests, is used to build stages. Stages are also Elixir processes and they’re our building blocks for creating data-processing pipelines.

The stages can receive events and use them to do some useful work. They can also send events to the next stage in the pipeline. Their most important feature is back-pressure.

There are three different types of stages available to us: producer, consumer, and producer-consumer.

## Building Yout Data-Processing Pipeline

We will build a fake service that scrapes data from web pages—normally an intensive task, dependent on system resources and a reliable network connection. Our goal is to be able to request a number of URLs to be scraped, and have the data pipeline take care of the workload.

Create a new project:
`mix new scraper --sup`

Now, add gen_stage library:
- in scraper/mix.exs:
```elixir
  defp deps do
    [
      {:gen_stage, "~> 1.0"}
    ]
  end
```

Run `mix do deps.get, compile` do download and compile all dependencies.

Let’s add a dummy function to scraper.ex which will simulate doing some time-consuming work.

- in scraper/lib/scraper.ex:
```elixir
  def work() do
    # For simplicity, this function is
    # just a placeholder and does not contain
    # real scraping logic.

    1..5
    |> Enum.random()
    |> :timer.seconds()
    |> Process.sleep()
  end
```

### Creating a Producer

- in scraper/lib/page_producer.ex:
```elixir
defmodule PageProducer do
  use GenStage
  require Logger

  def start_link(_args) do
    initial_state = []
    GenStage.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def init(initial_state) do
    Logger.info("PageProducer init")
    {:producer, initial_state}
  end
  
  def handle_demand(demand, state) do
    Logger.info("PageProducer received demand for #{demand} pages")
    events = []
    {:noreply, events, state}
  end
end
```

When a :consumer process asks for events, handle_demand/2 will be invoked with two parameters: the number of events requested by the consumers and the internal state of the producer. In the result tuple, the second element must be a list containing the actual events. Right now we are just returning an empty list, but we will revisit this part later.

### Create a Consumer

- in scraper/lib/page_consumer.ex:
```elixir
defmodule PageConsumer do
  use GenStage
  require Logger

  def start_link(_args) do
    initial_state = []
    GenStage.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def init(initial_state) do
    Logger.info("PageConsumer init")
    {:consumer, initial_state, subscribe_to: [PageProducer]}
  end

  def handle_events(events, _from, state) do
    Logger.info("PageConsumer received #{inspect(events)}")

    # Pretending that we're scraping web pages.
    Enum.each(events, fn _page ->
      Scraper.work()
    end)

    {:noreply, [], state}
  end
end
```

- Suscribing at Runtime
You can programmatically subscribe to a producer at runtime using sync_subscribe/3 and async_subscribe/3 from the GenStage module. This is useful when consumers and/or producers are created dynamically at runtime. Note that you will also have to handle the resubscribe yourself if the producer crashes and is restarted.

let’s add them to our application supervision tree in application.ex.

- in scraper/lib/scraper/application.ex:
```elixir
    children = [
      PageProducer,
      PageConsumer
    ]

    # or
    # children = [
    #   {PageProducer, []},
    #   {PageConsumer, []}
    # ]

```

Start iex shell:
`iex -S mix`

You will see:
```sh
17:31:30.526 [info] PageProducer init
 
17:31:30.531 [info] PageConsumer init
 
17:31:30.531 [info] PageProducer received demand for 1000 pages
```

The producer and consumer are talking to each other.

### Understanding Consumer Demand
By default, stages of type :consumer and :producer_consumer make sure that demand for new events is between 500 and 1000. You can configure this through the min_demand and max_demand settings.

Example:
```elixir
  sub_opts = [{PageProducer, min_demand: 500, max_demand: 1000}]
  {:consumer, initial_state, subscribe_to: sub_opts}
```

Let’s say the producer supplies 1000 events. The consumer will process the first batch using a simple formula:

events to process = max_demand - min_demand

Since max_demand is 1000 and min_demand is 500 by default, the consumer will process 500 events first, and then the remaining 500, according to the formula. This means that the handle_events/3 callback will be called with a list of 500 events initially, followed by another 500 when it is done processing the previous one.

- in scraper/lib/page_consumer.ex:
```elixir
  def init(initial_state) do
    Logger.info("PageConsumer init")
    sub_opts = [{PageProducer, min_demand: 0, max_demand: 3}]
    {:consumer, initial_state, subscribe_to: sub_opts}
  end
```

### Revisiting the Producer
we mentioned that GenStage is built on top of GenServer . This means that the callbacks we covered in GenServer Callbacks In Depth are also available for GenStage processes:

handle_call/3
handle_cast/2
handle_info/3

They will be called when you invoke GenStage.call/3 , GenStage.cast/2, or Process.send/3 , respectively. However, the return signatures of those callbacks have an important difference to their GenServer counterparts. Here are two examples of return tuples allowed for GenStage:

{:reply, reply, [event], new_state}
{:noreply, [event], new_state}

Let’s implement our API in PageProducer.
- in scraper/lib/page_producer.ex:
```elixir
  def scrape_pages(pages) when is_list(pages) do
    GenStage.cast(__MODULE__, {:pages, pages})
  end
  
  def handle_cast({:pages, pages}, state) do
    {:noreply, pages, state}
  end
```

Run the iex shell again:
`iex -S mix`

You will see:
```sh
18:08:20.686 [info] PageProducer init
 
18:08:20.691 [info] PageConsumer init
 
18:08:20.691 [info] PageProducer received demand for 3 pages
```

Since our handle_demand/2 callback does not return events, this initial demand is not satisfied and therefore the consumer will wait until events are available.


- in scraper/.iex.exs:
```elixir
pages = [
  "google.com",
  "facebook.com",
  "apple.com",
  "netflix.com",
  "amazon.com"
]
```

Run:
```sh
iex(3)> PageProducer.scrape_pages(pages)
:ok
iex(4)> 
18:12:54.508 [info] PageConsumer received ["google.com", "facebook.com", "apple.com"]
 
18:13:05.516 [info] PageProducer received demand for 1 pages
 
18:13:05.516 [info] PageConsumer received ["netflix.com", "amazon.com"]
```

We can see that PageConsumer immediately received the first three pages, which took a bit of time to process, judging by the timestamps. Since only two pages were available next, our consumer realized that it has capacity for one more page, so it immediately issued demand for another page, while starting work on the other two.

### Adding More Consumers

- in scraper/lib/page_consumer.ex:
```elixir
  def start_link(args) do
    initial_state = []
    name = Keyword.get(args, :name, :undefined)
    GenStage.start_link(__MODULE__, initial_state, name: name)
  end

  def init(initial_state) do
    Logger.info("PageConsumer init")
    sub_opts = [{PageProducer, min_demand: 0, max_demand: 1}]
    {:consumer, initial_state, subscribe_to: sub_opts}
  end
```

- in scraper/lib/scraper/application.ex:
```elixir
    children = [
      PageProducer,
      Supervisor.child_spec({PageConsumer, [name: :consumer_a]}, id: :consumer_a),
      Supervisor.child_spec({PageConsumer, [name: :consumer_b]}, id: :consumer_b)
    ]
```

Now our consumer will take only one event at a time, but we have two consumer processes running concurrently. As soon as one is free, it will issue demand to scrape another page.

As we saw, each process should have a unique ID in the supervision tree. We can also use the Registry module to assign a name to each process.

With this approach, we can add as many consumer processes as needed and GenServer will distribute the events for us, acting as a load balancer. Let’s try it:

```sh
iex(2)> PageProducer.scrape_pages(pages)
:ok

20:14:46.743 [info] PageConsumer received ["facebook.com"]
 
20:14:46.743 [info] PageConsumer received ["google.com"]
iex(3)> 
20:14:47.751 [info] PageConsumer received ["apple.com"]
 
20:14:47.752 [info] PageConsumer received ["netflix.com"]
 
20:14:48.752 [info] PageConsumer received ["amazon.com"]
 
20:14:49.753 [info] PageProducer received demand for 1 pages
 
20:14:52.752 [info] PageProducer received demand for 1 pages
```

You can call scrape_pages/1 even when the consumers are still busy, so events will be queued up automatically. It is important to understand how this works, so we’re going to briefly cover this next.

### Buffering Events
Producers keep dispatched events in memory. They have a built-in buffer which is used whenever the number of dispatched events is greater than the total pending demand. As we saw earlier, events staying in the buffer are automatically granted to consumers who issue demand.

The default size of the buffer is 10,000 events for stages of type :producer , and :infinity for type :producer_consumer . However, both can be configured with a fixed capacity of our choice or :infinity . In the init/1 callback, we can provide the optional buffer_size parameter in the return tuple. Let’s do a quick experiment and change the buffer_size to 1:

- in scraper/lib/page_producer.ex:
```elixir
  def init(initial_state) do
    Logger.info("PageProducer init")
    {:producer, initial_state, buffer_size: 1}
  end
```

- Dropping Events from the End of the Buffer

If you want to use a fixed-size buffer, you also have the option to discard events from the end of the queue when the :buffer_size limit is hit. Just pass the optional :buffer_keep param and set it to :first (the default value is :last).


Rerun the application.
```sh
iex(1)> pages = [      
   "google.com",  
   "facebook.com",
   "apple.com",   
   "netflix.com", 
   "amazon.com"   
 ]
["google.com", "facebook.com", "apple.com", "netflix.com", "amazon.com"]
iex(2)> PageProducer.scrape_pages(pages)

20:32:19.525 [info] PageConsumer received ["facebook.com"]
 
20:32:19.525 [info] PageConsumer received ["google.com"]
:ok
iex(3)> 
20:32:19.525 [warning] GenStage producer PageProducer has discarded 2 events from buffer
 
20:32:20.538 [info] PageConsumer received ["amazon.com"]
 
20:32:23.538 [info] PageProducer received demand for 1 pages
 
20:32:25.539 [info] PageProducer received demand for 1 pages
```

Using the built-in buffer is convenient for most use cases. If you need fine-grain control over the number of events produced and dispatched, you may want to look into implementing your own queue for storing produced events and pending demand. Erlang’s :queue is a great option as it is already available in Elixir. Such a queue could be stored in producer’s state, and used to dispatch events only when demand has been registered in handle_demand/3 . This will also give you an opportunity to implement your custom logic for discarding events— useful if you want to prioritize one type of event over another.

## Adding Concurrency with ConsumerSupervisor

### Creating a ConsumerSupervisor
- in scraper/lib/page_consumer_supervisor.ex:
```elixir
defmodule PageConsumerSupervisor do
  use ConsumerSupervisor
  require Logger

  def start_link(_args) do
    ConsumerSupervisor.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    Logger.info("PageConsumerSupervisor init")

    # The only restart options supported are :temporary and :transient .
    children = [
      %{
        id: PageConsumer,
        start: {PageConsumer, :start_link, []},
        restart: :transient
      }
    ]

    opts = [
      strategy: :one_for_one,
      subscribe_to: [
        {PageProducer, max_demand: 2}
      ]
    ]

    ConsumerSupervisor.init(children, opts)
  end
end
```

State is not relevant for ConsumerSupervisor , so we simply pass an :ok atom.
max_demand defined with 2 means that two consumers (at most) could run concurrently.

### The Simplified Consumer
Refactor PageConsumer.
- in scraper/lib/page_consumer.ex:
```elixir
defmodule PageConsumer do
  require Logger

  def start_link(event) do
    Logger.info("PageConsumer received #{event}")

    Task.start_link(fn ->
      Scraper.work()
    end)
  end
end
```

Remember that we told PageConsumerSupervisor to subscribe to PageProducer for events. This means that PageConsumerSupervisor has effectively taken the place of a :consumer in our data-processing pipeline. However, PageConsumerSupervisor only manages demand, receives events, and starts new processes. It doesn’t do any work.

### Put It All Together
- in scraper/lib/scraper/application.ex:
```elixir
    children = [
      PageProducer,
      PageConsumerSupervisor
    ]
```

Remember to remove the buffer update.
- in scraper/lib/page_producer.ex:
```elixir
  def init(initial_state) do
    Logger.info("PageProducer init")
    {:producer, initial_state}
  end
```

Let’s rerun our application and call PageProducer.scrape_pages/1 in the IEx shell.

```sh
iex(1)> pages = [      
  "google.com",  
  "facebook.com",
  "apple.com",   
  "netflix.com", 
  "amazon.com"   
]
["google.com", "facebook.com", "apple.com", "netflix.com", "amazon.com"]
iex(2)> PageProducer.scrape_pages(pages)
:ok
iex(3)> 
19:28:21.424 [info] PageConsumer received google.com
 
19:28:21.424 [info] PageConsumer received facebook.com
 
19:28:24.432 [info] PageConsumer received apple.com
 
19:28:26.432 [info] PageConsumer received netflix.com
 
19:28:27.433 [info] PageConsumer received amazon.com
 
19:28:28.434 [info] PageProducer received demand for 1 pages
 
19:28:30.435 [info] PageProducer received demand for 1 pages
```

- How To Find Out the Number of Logical Cores at Runtime?

In Elixir, you can get the number of logical cores available programmatically by calling System.schedulers_online(). This could be useful if you want to set ConsumerSupervisor ’s max_demand dynamically, for example:

max_demand = System.schedulers_online() * 2

My personal laptop has a CPU with four logical cores, so max_demand will be eight using the formula above.



Keep in mind that all child processes must exit with reason :normal or :shutdown , so the supervisor can reissue demand. You can do this by returning {:stop, :normal, state} from a process callback when you’re ready to terminate it.

## Creating Multi-Stage Data Pipelines

- in scraper/lib/scraper.ex:
```elixir
  def online?(_url) do
    # Pretend we are checking if the
    # service is online or not.
    work()
    
    # Select result randomly.
    Enum.random([false, true, true])
  end
```

### Adding a Producer-Consumer
- in scraper/lib/online_page_producer_consumer.ex:
```elixir
defmodule OnlinePageProducerConsumer do
  use GenStage
  require Logger

  def start_link(_args) do
    initial_state = []
    GenStage.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def init(initial_state) do
    Logger.info("OnlinePageProducerConsumer init")

    subscription = [
      {PageProducer, min_demand: 0, max_demand: 1}
    ]

    {:producer_consumer, initial_state, subscribe_to: subscription}
  end

  def handle_events(events, _from, state) do
    Logger.info("OnlinePageProducerConsumer received #{inspect(events)}")

    events = Enum.filter(events, &Scraper.online?/1)
    {:noreply, events, state}
  end
end
```

### Rewriting Our Pipeline

- in scraper/lib/page_consumer_supervisor.ex:
```elixir
    opts = [
      strategy: :one_for_one,
      subscribe_to: [
        {OnlinePageProducerConsumer, max_demand: 2}
      ]
    ]
```

- in scraper/lib/scraper/application.ex:
```elixir
    children = [
      PageProducer,
      OnlinePageProducerConsumer,
      PageConsumerSupervisor
    ]
```

Producers always have to be started before the consumers.

Test:
```sh
iex(1)> PageProducer.scrape_pages(pages)
:ok

19:17:22.814 [info] OnlinePageProducerConsumer received ["google.com"]
iex(2)> 
19:17:25.823 [info] OnlinePageProducerConsumer received ["facebook.com"]
 
19:17:27.824 [info] OnlinePageProducerConsumer received ["apple.com"]
 
19:17:27.825 [info] PageConsumer received facebook.com
 
19:17:28.825 [info] OnlinePageProducerConsumer received ["netflix.com"]
 
19:17:29.825 [info] PageConsumer received netflix.com
 
19:17:29.826 [info] OnlinePageProducerConsumer received ["amazon.com"]
 
19:17:34.827 [info] PageConsumer received amazon.com
 
19:17:34.827 [info] PageProducer received demand for 1 pages
```

### Scaling Up a Stage with Extra Processes

- in scraper/lib/scraper/application.ex:
```elixir
def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ProducerConsumerRegistry},
      PageProducer,
      producer_consumer_spec(id: 1),
      producer_consumer_spec(id: 2),
      PageConsumerSupervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Scraper.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
  def producer_consumer_spec(id: id) do
    id = "online_page_producer_consumer_#{id}"
    Supervisor.child_spec({OnlinePageProducerConsumer, id}, id: id)
  end
```

- in scraper/lib/online_page_producer_consumer.ex:
```elixir
  def start_link(id) do
    initial_state = []
    GenStage.start_link(__MODULE__, initial_state, name: via(id))
  end
  
  def via(id) do
    {:via, Registry, {ProducerConsumerRegistry, id}}
  end
```

We use the ProducerConsumerRegistry we created earlier to store a reference to our process.

- in scraper/lib/page_consumer_supervisor.ex:
```elixir
    opts = [
      strategy: :one_for_one,
      subscribe_to: [
        {OnlinePageProducerConsumer.via("online_page_producer_consumer_1"), []},
        {OnlinePageProducerConsumer.via("online_page_producer_consumer_2"), []}
      ]
    ]
```

Test:
```sh
iex(1)> PageProducer.scrape_pages(pages)
:ok
iex(2)> 
19:30:04.723 [info] OnlinePageProducerConsumer received ["google.com"]
 
19:30:04.723 [info] OnlinePageProducerConsumer received ["facebook.com"]
 
19:30:05.731 [info] OnlinePageProducerConsumer received ["apple.com"]
 
19:30:05.732 [info] PageConsumer received google.com
 
19:30:09.731 [info] PageConsumer received facebook.com
 
19:30:09.731 [info] OnlinePageProducerConsumer received ["netflix.com"]
 
19:30:09.733 [info] OnlinePageProducerConsumer received ["amazon.com"]
 
19:30:10.732 [info] PageConsumer received netflix.com
 
19:30:10.732 [info] PageProducer received demand for 1 pages
 
19:30:13.734 [info] PageProducer received demand for 1 pages
 
19:30:13.734 [info] PageConsumer received amazon.com
```

## Choosing the Right Dispatcher

When :producer and :producer_consumer stages send events to consumers, it’s in fact the dispatcher that takes care of sending the events. So far we have used the default DemandDispatcher , but GenStage comes with two more.

The default is DemandDispatcher , which is equivalent to this
configuration:

```elixir
def init(state) do
  {:producer, state, dispatcher: GenStage.DemandDispatcher}
end
```

DemandDispatcher sends events to consumers with the highest demand first. It is the dispatcher that you’re going to use most often.

### Using BroadcastDispatcher
You can use the BroadcastDispatcher this way:

{:producer, state, dispatcher: GenStage.BroadcastDispatcher}

As its name suggests, BroadcastDispatcher sends the events supplied by the :producer or :producer_consumer to all consumers subscribed to it.

When BroadcastDispatcher is used, consumer stages get the ability to filter the events they are receiving. This means that each consumer can opt-in for specific events, and discard the rest. All you have to do is use the :selector setting when subscribing to the producer, like so:

```elixir
def init(state) do
  selector =
    fn incoming_event ->
      # you can use the event to decide whether
      # to return `true` and accept it, or `false` to reject it.
    end
    
  sub_opts = [
    {SomeProducer, selector: selector}
  ]
  
  {:consumer, state, subscribe_to: sub_opts}
end
```

### Using PartitionDispatcher

Unlike BroadcastDispatcher , where the consumer has to check each event, PartitionDispatcher leaves this responsibility to the producer.

There are two extra arguments that we need to pass when configuring PartitionDispatcher — :partitions and :hash . Here is an example:

```elixir
def init(state) do
  hash =
    fn event ->
      # you can use the event to decide which partition
      # to assign it to, or use `:none` to ignore it.

      event, :c}
    end

  opts = [
    partitions: [:a, :b, :c],
    hash: hash
  ]

  {:producer, state, dispatcher: {GenStage.ParitionDispatcher, opts}}
end
```

Now that the producer is configured, consumers can subscribe to one of the partitions when initializing:

```elixir
sub_opts = [
  {SomeProducer, partition: :b}
]

{:consumer, state, subscribe_to: sub_opts}
```

However, if these dispatchers still don’t quite match what you are trying to accomplish, you can also create your own dispatcher from scratch, by implementing the GenStage.Dispatcher behaviour. Check out the Dispatcher module documentation for more information on what callbacks you have to implement.