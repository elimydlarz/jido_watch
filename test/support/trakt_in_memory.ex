defmodule JidoWatch.Test.Support.TraktInMemory do
  @moduledoc """
  In-memory twin of the Trakt API for tests.

  Seeded with a `code -> tokens` map and a list of watch entries.
  `exchange_code/2` returns the seeded tokens for matching codes and
  `{:error, :invalid_code}` otherwise. `recent_watches/2` returns the seeded
  watches and counts how many times it was called so tests can assert on
  polling.
  """

  @behaviour JidoWatch.Trakt.Client

  use Agent

  def start!(opts \\ []) do
    codes = Keyword.get(opts, :codes, %{})
    watches = Keyword.get(opts, :watches, [])
    recent_watches_error = Keyword.get(opts, :recent_watches_error)

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          codes: codes,
          watches: watches,
          recent_watches_error: recent_watches_error,
          recent_watches_calls: 0
        }
      end)

    {__MODULE__, pid}
  end

  @impl JidoWatch.Trakt.Client
  def exchange_code(pid, code) do
    case Agent.get(pid, fn state -> Map.get(state.codes, code) end) do
      nil -> {:error, :invalid_code}
      tokens -> {:ok, tokens}
    end
  end

  @impl JidoWatch.Trakt.Client
  def recent_watches(pid, _access_token) do
    Agent.get_and_update(pid, fn state ->
      {{:ok, state.watches}, Map.update!(state, :recent_watches_calls, &(&1 + 1))}
    end)
  end

  def recent_watches_calls({__MODULE__, pid}) do
    Agent.get(pid, & &1.recent_watches_calls)
  end
end
