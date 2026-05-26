defmodule JidoWatch.Actions.PollWatches do
  @moduledoc """
  Drives one tick of the watching pipeline: fetches recent watches from Trakt
  via `JidoWatch.Watching.run/1`, which feeds the agent's three callbacks.

  Gated by connection: an agent without Trakt tokens does no Trakt I/O at all.

  Refreshes the access token when Trakt returns `:unauthorized` and replays the
  tick once with the new tokens. Refresh tokens rotate on every use, so the
  new pair atomically replaces the old in plugin state. Transient HTTP failures
  (5xx, 408, 429, transport errors) are retried inside the Trakt and subtitle
  adapters via Req's `:safe_transient` retry policy — not here.
  """

  use Jido.Action,
    name: "poll_watches",
    description: "Poll Trakt for new watches for the connected user.",
    schema: []

  alias JidoWatch.Watching

  @impl Jido.Action
  def run(_params, %{agent: agent}) do
    plugin_state = Map.fetch!(agent.state, :__jido_watch__)
    poll_for_connection(plugin_state.connection, plugin_state, agent)
  end

  defp poll_for_connection({:connected, tokens}, plugin_state, agent) do
    case run_pipeline(plugin_state, tokens, agent) do
      {:ok, updates} ->
        {:ok, %{__jido_watch__: Map.merge(plugin_state, updates)}}

      {:error, :unauthorized} ->
        refresh_and_replay(plugin_state, tokens, agent)

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp poll_for_connection(:unconnected, _plugin_state, _agent), do: {:ok, %{}}

  defp refresh_and_replay(plugin_state, %{refresh_token: refresh_token}, agent) do
    {trakt_mod, trakt_handle} = plugin_state.trakt

    case trakt_mod.exchange_refresh_token(trakt_handle, refresh_token) do
      {:ok, new_tokens} ->
        new_plugin_state = %{plugin_state | connection: {:connected, new_tokens}}

        case run_pipeline(new_plugin_state, new_tokens, agent) do
          {:ok, updates} ->
            {:ok, %{__jido_watch__: Map.merge(new_plugin_state, updates)}}

          {:error, _} ->
            {:ok, %{__jido_watch__: new_plugin_state}}
        end

      {:error, :invalid_grant} ->
        {:ok, %{__jido_watch__: %{plugin_state | connection: :unconnected}}}

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp run_pipeline(plugin_state, %{access_token: access_token}, agent) do
    case Watching.run(%{
           trakt: plugin_state.trakt,
           subtitles: plugin_state.subtitles,
           access_token: access_token,
           host: agent.agent_module,
           agent: agent,
           angles: plugin_state.angles,
           watermark: plugin_state.watermark,
           pending_watches: plugin_state.pending_watches
         }) do
      {:ok, %{watermark: wm, pending_watches: pw} = result} ->
        updates = %{watermark: wm, pending_watches: pw}

        updates =
          if result[:subtitles], do: Map.put(updates, :subtitles, result.subtitles), else: updates

        {:ok, updates}

      {:error, _} = err ->
        err
    end
  end
end
