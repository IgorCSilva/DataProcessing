# Processing Collections with Flow

## Analyzing Airports Data
We are going to build a simple utility to help us analyze airport data by country. We will see which countries and territories have the biggest number of working airports in the world.

`mix new airports`

- in airports/mix.exs:
```elixir
  defp deps do
    [
      {:flow, "~> 1.0"},
      {:nimble_csv, "~> 1.1"}
    ]
  end
```

Run `mix deps.get`.

Download the airports.csv file (https://ourairports.com/data/).
Next, within the airports project folder, create a folder called priv . Copy and paste the airports.csv file there.

- in :
```elixir
defmodule Airports do

  alias NimbleCSV.RFC4180, as: CSV

  def airports_csv() do
    Application.app_dir(:airports, "/priv/airports.csv")
  end
end
```

The Application.app_dir/1 helper returns the full path to the :airports application, while the second argument in app_dir/2 appends the path within that application folder and returns it.

## Creating Flows and Reading Files

- in airports/lib/airports.ex:
```elixir
  def open_airports() do
    airports_csv()
    |> File.read!()
    |> CSV.parse_string()
    |> Enum.map(fn row ->
      %{
        id: Enum.at(row, 0),
        type: Enum.at(row, 2),
        name: Enum.at(row, 3),
        country: Enum.at(row, 8)
      }
    end)
    |> Enum.reject(&(&1.type == "closed"))
  end
```

Let's see how many time the function needs to complete.

```sh
:timer.tc(&Airports.open_airports/0)
{5432365,
 [
   %{country: "US", id: "6523", name: "Total RF Heliport", type: "heliport"},
   %{
     country: "US",
     id: "323361",
     name: "Aero B Ranch Airport",
     type: "small_airport"
   },
   %{country: "US", id: "6524", name: "Lowell Field", type: "small_airport"},
   %{country: "US", id: "6525", name: "Epps Airpark", type: "small_airport"},
   ...
 ]
}
```

- Benchmarking Functions
If you want to benchmark performance, it is best to use a benchmarking library, such as benchee.

### Improving Performance with Streams

- in airports/lib/airports.ex:
```elixir
  def open_airports() do
    airports_csv()
    |> File.stream!()
    |> CSV.parse_stream()
    |> Stream.map(fn row ->
      %{
        id: :binary.copy(Enum.at(row, 0)),
        type: :binary.copy(Enum.at(row, 2)),
        name: :binary.copy(Enum.at(row, 3)),
        country: :binary.copy(Enum.at(row, 8))
      }
    end)
    |> Stream.reject(&(&1.type == "closed"))
    |> Enum.to_list()
  end
```

Run recompile and test:
```sh
:timer.tc(&Airports.open_airports/0)
{694804,
 [
   %{country: "US", id: "6523", name: "Total RF Heliport", type: "heliport"},
   %{
     country: "US",
     id: "323361",
     name: "Aero B Ranch Airport",
     type: "small_airport"
   },
   ...
 ]
}
```

We achieved eight times better performance with just a few small changes.

- Working with JSON Files
Unlike the CSV format, JSON is a lot more complicated to parse. At the time of writing, the most popular JSON parsers for Elixir, Jason and Poison , do not support streaming. If you are working with large
JSON files, check out Erlang’s jsx or Elixir’s Jaxon.

### Running Streams Concurrently
To use Flow , we need to convert an existing data source first. The result of the conversion is called a flow.

- in airports/lib/airports.ex:
```elixir
  def open_airports() do
    airports_csv()
    |> File.stream!()
    |> CSV.parse_stream()
    |> Flow.from_enumerable()
    |> Flow.map(fn row ->
      %{
        id: :binary.copy(Enum.at(row, 0)),
        type: :binary.copy(Enum.at(row, 2)),
        name: :binary.copy(Enum.at(row, 3)),
        country: :binary.copy(Enum.at(row, 8))
      }
    end)
    |> Flow.reject(&(&1.type == "closed"))
    |> Enum.to_list()
  end
```

```sh
{2091300,
 [
   %{
     country: "US",
     id: "6523",
     name: "Total RF Heliport",
     type: "heliport"
   },
   ...
 ]
}
```

However, this version is slower.

The flow is based on a single data source—the result of the parse_stream/1 function— which might have trouble keeping up. Let’s move the parsing logic into the Flow.map/2 function, so it runs concurrently with the rest of the code.

- in airports/lib/airports.ex:
```elixir
  def open_airports() do
    airports_csv()
    |> File.stream!()
    |> Flow.from_enumerable()
    |> Flow.map(fn row ->
      [row] = CSV.parse_string(row, skip_headers: false)
      
      %{
        id: Enum.at(row, 0),
        type: Enum.at(row, 2),
        name: Enum.at(row, 3),
        country: Enum.at(row, 8)
      }
    end)
    |> Flow.reject(&(&1.type == "closed"))
    |> Enum.to_list()
  end
```

Let's try it:
```sh
iex(3)> :timer.tc(&Airports.open_airports/0)
{380951,
 [ 
   %{country: "iso_country", id: "id", name: "name", type: "type"},
   ...
 ]
}
```

Now we have 380ms, fourteen times better than the first version time.

### Understanding Flows
Under the hood, a flow is a simple %Flow{} struct.
When we used from_enumerable/2 , Flow would treat the data source as a producer, where each element is sent down the flow as a GenStage event. Operations like Flow.map/2 and Flow.filter/2 will act as :consumer or :producer_consumer stages.

Flow lets you configure the stage processes by passing a list of options as the second argument in from_enumerable/2 . As you know, the number of stage processes determines the level of concurrency. By default, Flow uses the value of System.schedulers_online/0 . This is usually the total number of virtual cores your machine has. You can change this by passing the :stages option and giving it an integer as the value. You can also tweak the demand by passing :max_demand and :min_demand , just like we did with GenStage.

## Performing Reduce Concurrently with Partitions

Just like with Flow.map/2 , each reducer function will run concurrently by default. Since each reducer function runs in its own process, it has no knowledge of other accumulator values. The final outcome will be the combined list of all results, which will contain duplicates.

- in airports/lib/airports.ex:
```elixir
  ...
  |> Flow.reject(&(&1.type == "closed"))
  |> Flow.reduce(fn -> %{} end, fn item, acc ->
    Map.update(acc, item.country, 1, &(&1 + 1))
  end)
  |> Enum.to_list()
```

You can use IO.inspect/2 with the :limit option set to
:infinity to see everything:
`Airports.open_airports() |> IO.inspect(limit: :infinity)`

When inspecting the result on your machine, notice that many country codes appear more than once.

### Routing Events with Partitions
The real solution to our problem is partitioning. Flow provides a function called partition/2 , which creates another layer of stages that act like a router.

- in airports/lib/airports.ex:
```elixir
    ...
    |> Flow.reject(&(&1.type == "closed"))
    |> Flow.partition(key: {:key, :country})
    |> Flow.reduce(fn -> %{} end, fn item, acc ->
      Map.update(acc, item.country, 1, &(&1 + 1))
    end)
    |> Enum.to_list()
```

Run again and you will see the correct results.


`Airports.open_airports()`


The :key option accepts three types of values:
- {:elem, position} - for tuples, where position is an integer, so you can specify which element in the tuple to use as the key;
- {:key, key} - for maps, where key is a top-level key, and could be either an atom or a string;
- An anonymous function returning a key, for more complex cases, like nested maps or computing the key based on several values. The function receives the item as an argument, for example, fn item -> .. end.

### Grouping and Sorting

Grouping.
- in airports/lib/airports.ex:
```elixir
    ...
    |> Flow.reject(&(&1.type == "closed"))
    |> Flow.partition(key: {:key, :country})
    |> Flow.group_by(&(&1.country))
    |> Flow.on_trigger(fn data ->
      {Enum.map(data, fn {country, data} -> {country, Enum.count(data)} end), data}
    end)
    |> Enum.to_list()
```

```sh
iex(2)> Airports.open_airports()
[       
  {"BA", 16},
  {"CD", 273},
  {"CX", 1},
  {"EG", 129},
  {"GA", 40},
  {"GM", 1},
  {"KZ", 162},
  {"ME", 6},
  ...

]
```

Sorting.
- in airports/lib/airports.ex:
```elixir
    ...
    |> Flow.reject(&(&1.type == "closed"))
    |> Flow.partition(key: {:key, :country})
    |> Flow.group_by(&(&1.country))
    |> Flow.on_trigger(fn data ->
      {Enum.map(data, fn {country, data} -> {country, Enum.count(data)} end), data}
    end)
    |> Flow.take_sort(10, fn {_, a}, {_, b} -> a > b end)
    |> Enum.to_list()
    |> List.flatten()
```

```sh
iex(5)> :timer.tc(&Airports.open_airports/0)
{380955,
 [
   {"US", 24438},
   {"BR", 6669},
   {"JP", 3127},
   {"AU", 2549},
   {"CA", 2316},
   {"MX", 1950}, 
   {"KR", 1364},
   {"RU", 1285},
   {"DE", 1230},
   {"GB", 1140}
 ]} 
```

- Running a Flow
Similar to streams, we’ve been using Enum.to_list/0 at the end of our flow pipelines, which forces them to run and produce a result. However, if you’re not interested in the final result, you can use Flow.run/1 instead of Enum.to_list/0 . It works similar to Stream.run/1 and always returns :ok.

## Using Windows and Triggers

We have some types of windows:

- global (Flow.Window.global/0): creates a global window that group all events togeter and close only when all events have been received;
- fixed (Flow.Window.fixed/3): groups events by a timestamp value on the event, using specified time duration;
- periodic (Flow.Window.periodic/2): is like fixed/3 but groups events by processing time;

- count (Flow.Window.count/1): groups events when they reach the given count.

Windows also influence how reducer operations work. At the beginning of a window, the accumulator is reset, so it can start collecting data again from scratch. Remember that Flow.reduce/3 uses a function to create the initial accumulator value. This function is called at the beginning of each window.

You can also specify a trigger for each window. Triggers work like checkpoints and all trigger functions take a window as their first argument. When a trigger event occurs, you have the opportunity to take data out of the flow by specifying what events to emit. You can even change the accumulator value on-the-fly.

These are available triggers:
- Flow.Window.trigger_every/2: triggers when you reach the given count of events;
- Flow.Window.trigger_periodically/3: triggers at the specified time duration;
- Flow.Window.trigger/3: is used for implementing custom triggers.

By default, every flow has an internal trigger for an event called :done, which occurs when there is no data left to process.

### Catching Trigger Events with on_trigger/2

### Getting Snapshot from Slow-Running or Infinite Flows

First, let's slowing the stream of events:
- in airports/lib/airports.ex:
```elixir
    airports_csv()
    |> File.stream!()
    |> Stream.map(fn event ->
      Process.sleep(Enum.random([0, 0, 0, 1]))
      event
    end)
    |> Flow.from_enumerable()
```

You can try running this version of the code; it should take about a minute to complete.

Define the window variable at the top of the function.
- in airports/lib/airports.ex:
```elixir
    window = Flow.Window.trigger_every(Flow.Window.global(), 1000)
    
    airports_csv()
    |> File.stream!()
```

Now give it as an argument to Flow.partition/2.
- in airports/lib/airports.ex:
```elixir
    |> Flow.reject(&(&1.type == "closed"))
    |> Flow.partition(window: window, key: {:key, :country})
    |> Flow.group_by(&(&1.country))
```

Add the trigger logic.
- in airports/lib/airports.ex:
```elixir
    |> Flow.group_by(&(&1.country))
    |> Flow.on_trigger(fn acc, _partition_info, {_type, _id, trigger} ->
      
      # Show progress in IEx, or use the data for something else.
      events =
        acc
        |> Enum.map(fn {country, data} -> {country, Enum.count(data)} end)
        |> IO.inspect(label: inspect(self()))
        
      case trigger do
        :done ->
          {events, acc}
        {:every, 1000} ->
          {[], acc}  
      end
    end)
    |> Enum.to_list()
```

When the :done trigger happens, we emit the final result as a list of tuples. In case of {:every, 1000} , we do not emit anything, since we’re not finished processing yet.

Let’s run this in IEx .
```sh
iex(4)> Airports.open_airports()
#PID<0.310.0>: [{"MP", 1}, {"US", 998}, {"iso_country", 1}]
#PID<0.310.0>: [{"MP", 1}, {"US", 1998}, {"iso_country", 1}]
#PID<0.310.0>: [{"MP", 1}, {"US", 2998}, {"iso_country", 1}]
#PID<0.310.0>: [{"MP", 1}, {"US", 3998}, {"iso_country", 1}]
...
```

We can use Flow.departition/5 , which merges all existing
stages into one using the provided merger function. In this particular case, the number of events in the result is small enough to be easily processed using the Enum module. If you want to return only the top ten countries, you can replace Enum.to_list() with this:

- in airports/lib/airports.ex:
```elixir
    |> Enum.sort(fn {_, a}, {_, b} -> a > b end)
    |> Enum.take(10)
```

## Adding Flow to a GenStage Pipeline

To demonstrate how Flow works with GenStage , we are going to rewrite the original OnlinePageConsumerProducer implementation using Flow.

There are two groups of functions available to use. The first group is made to work with already running stages:

- from_stage/2: to receive events from :producer stages;
- through_stages/3: to send events to :producer_consumer stages and receive what they send in turn;
- into_stages/3: to send events to :consumer or :producer_consumer stages.

All functions in this group require a list of the process ids ( PID s) to connect to the already running processes.

The second group of functions is useful when you want Flow to start the GenStage processes for you:

- from_specs/2
- through_specs/3
- into_specs3

They work exactly the same way as the ones in the previous group, except that they require a list of tuples instead of a list of PIDs.

- in scraper/mix.exs:
```elixir
  defp deps do
    [
      {:gen_stage, "~> 1.0"},
      {:flow, "~> 1.0"}
    ]
  end
```

Run `mix deps.get`.

Next, replace the contents of OnlinePageProducerConsumer with this:
```elixir
defmodule OnlinePageProducerConsumer do
  use Flow

  def start_link(_args) do
    producers = [Process.whereis(PageProducer)]
    consumers = [{Process.whereis(PageConsumerSupervisor), max_demand: 2}]

    Flow.from_stages(producers, max_demand: 1, stages: 2)
    |> Flow.filter(&Scraper.online?/1)
    |> Flow.into_stages(consumers)
  end
end
```

Flow.into_stages/3 will handle the start_link/2 logic for us.

We need the PID of PageProducer , so we used Process.whereis/1 to get it by name. This is then used by Flow.from_stages/2 to subscribe to the producer.

Previously, we used the Registry to name and start two instances of OnlinePageConsumerProducer . This is no longer needed, since we can set :stages to 2 in from_stages/2 . This means that Flow will start two processes to manage the incoming workload. We also set :max_demand to 1 just like before, since the work we’re doing is CPU intensive. This is why the via/1 function is no longer needed and can be safely removed.

- in scraper/lib/scraper/application.ex:
```elixir
    children = [
      PageProducer,
      PageConsumerSupervisor,
      OnlinePageProducerConsumer
    ]

```

Finally, we need to explicitly set the :name argument when starting PageConsumerSupervisor , since we’re now using it to identify the process:

- in scraper/lib/page_consumer_supervisor.ex:
```elixir
  def start_link(_args) do
    ConsumerSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    ...

    opts = [
      strategy: :one_for_one,
      subscribe_to: []
    ]

    ConsumerSupervisor.init(children, opts)
  end
```

```sh
iex(4)> PageProducer.scrape_pages(pages)
:ok
iex(5)> 
20:11:20.456 [info] PageConsumer received netflix.com
 
20:11:21.456 [info] PageConsumer received apple.com
 
20:11:21.456 [info] PageProducer received demand for 1 pages
 
20:11:25.457 [info] PageConsumer received amazon.com
 
20:11:25.457 [info] PageProducer received demand for 1 pages
```

Everything works just like before.

- Caution When Using into_stages/3 and through_stages/3
Coordinating events and processes when using into_stages/3 and through_stages/3 could be complicated. If you are using them to process finite data, you have to be careful how processes exit—see the documentation for more information.

## Wrapping Up
You get the best results from Flow only when you use it with large data sets or to perform hardware-intensive work.