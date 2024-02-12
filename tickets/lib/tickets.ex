defmodule Tickets do

  def tickets_available?(_event) do
    Process.sleep(Enum.random(100..200))
    true
  end

  def create_ticket(_user, _event) do
    Process.sleep(Enum.random(250..1000))
  end

  def insert_all_tickets(messages) do
    Process.sleep(Enum.count(messages) * 250)
    messages
  end

  def send_email(_user) do
    Process.sleep(Enum.random(100..20))
  end

  @users [
    %{id: "1", email: "foo@email.com"},
    %{id: "2", email: "bar@email.com"},
    %{id: "3", email: "baz@email.com"}
  ]

  def users_by_ids(ids) when is_list(ids) do
    # Database query selecting users by ids.
    Enum.filter(@users, & &1.id in ids)
  end
end
