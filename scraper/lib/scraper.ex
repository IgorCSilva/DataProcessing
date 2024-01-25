defmodule Scraper do
  @moduledoc """
  Documentation for `Scraper`.
  """

  def work() do
    # For simplicity, this function is
    # just a placeholder and does not contain
    # real scraping logic.

    1..5
    |> Enum.random()
    |> :timer.seconds()
    |> Process.sleep()
  end

  def online?(_url) do
    # Pretend we are checking if the
    # service is online or not.
    work()

    # Select result randomly.
    Enum.random([false, true, true])
  end
end
