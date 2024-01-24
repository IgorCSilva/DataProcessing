defmodule PageConsumer do
  use GenStage
  require Logger

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

  def handle_events(events, _from, state) do
    Logger.info("PageConsumer received #{inspect(events)}")

    # Pretending that we're scraping web pages.
    Enum.each(events, fn _page ->
      Scraper.work()
    end)

    {:noreply, [], state}
  end

  def terminate(_reason, _state) do
    Logger.info("PageConsumer terminated")
    :ok
  end
end
