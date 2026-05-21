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
    unauthorized = MapSet.new(Keyword.get(opts, :unauthorized_access_tokens, []))
    refresh_chain = Keyword.get(opts, :refresh_chain, %{})

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          codes: codes,
          watches: watches,
          recent_watches_error: recent_watches_error,
          recent_watches_calls: 0,
          unauthorized_access_tokens: unauthorized,
          refresh_chain: refresh_chain
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
  def recent_watches(pid, access_token) do
    Agent.get_and_update(pid, fn state ->
      {result, new_state} =
        cond do
          MapSet.member?(state.unauthorized_access_tokens, access_token) ->
            {{:error, :unauthorized}, state}

          state.transient_failures_remaining > 0 ->
            {{:error, state.transient_error},
             Map.update!(state, :transient_failures_remaining, &(&1 - 1))}

          state.recent_watches_error ->
            {{:error, state.recent_watches_error}, state}

          true ->
            {{:ok, state.watches}, state}
        end

      {result, Map.update!(new_state, :recent_watches_calls, &(&1 + 1))}
    end)
  end

  @impl JidoWatch.Trakt.Client
  def exchange_refresh_token(pid, refresh_token) do
    Agent.get_and_update(pid, fn state ->
      cond do
        state.refresh_transient_failures_remaining > 0 ->
          {{:error, state.transient_error},
           Map.update!(state, :refresh_transient_failures_remaining, &(&1 - 1))}

        true ->
          case Map.fetch(state.refresh_chain, refresh_token) do
            {:ok, new_tokens} ->
              new_state =
                state
                |> Map.update!(:refresh_chain, &Map.delete(&1, refresh_token))
                |> Map.update!(
                  :unauthorized_access_tokens,
                  &MapSet.delete(&1, new_tokens.access_token)
                )

              {{:ok, new_tokens}, new_state}

            :error ->
              {{:error, :invalid_grant}, state}
          end
      end
    end)
  end

  def recent_watches_calls({__MODULE__, pid}) do
    Agent.get(pid, & &1.recent_watches_calls)
  end
end
