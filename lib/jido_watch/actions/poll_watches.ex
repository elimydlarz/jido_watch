defmodule JidoWatch.Actions.PollWatches do
  @moduledoc """
  Drives one tick of the watching pipeline: fetches recent watches from Trakt
  via `JidoWatch.Watching.run/1`, which feeds the agent's three callbacks.

  Gated by connection: an agent without Trakt tokens does no Trakt I/O at all.

  Refreshes the access token when Trakt returns `:unauthorized` and retries the
  tick once with the new tokens. Refresh tokens rotate on every use, so the
  new pair atomically replaces the old in plugin state.
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

  @max_attempts 3

  defp poll_for_connection({:connected, tokens}, plugin_state, agent) do
    case run_with_retry(plugin_state, tokens, agent, 1) do
      {:ok, new_watermark} ->
        {:ok, %{__jido_watch__: %{plugin_state | watermark: new_watermark}}}

      {:error, :unauthorized} ->
        refresh_and_retry(plugin_state, tokens, agent)

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp poll_for_connection(:unconnected, _plugin_state, _agent), do: {:ok, %{}}

  defp run_with_retry(plugin_state, tokens, agent) do
    with_retry(fn -> run_pipeline(plugin_state, tokens, agent) end, plugin_state.transient_retry_delay_ms)
  end

  defp refresh_and_retry(plugin_state, %{refresh_token: refresh_token}, agent) do
    {trakt_mod, trakt_handle} = plugin_state.trakt

    case with_retry(
           fn -> trakt_mod.exchange_refresh_token(trakt_handle, refresh_token) end,
           plugin_state.transient_retry_delay_ms
         ) do
      {:ok, new_tokens} ->
        new_plugin_state = %{plugin_state | connection: {:connected, new_tokens}}

        case run_with_retry(new_plugin_state, new_tokens, agent) do
          {:ok, new_watermark} ->
            {:ok, %{__jido_watch__: %{new_plugin_state | watermark: new_watermark}}}

          {:error, _} ->
            {:ok, %{__jido_watch__: new_plugin_state}}
        end

      {:error, :invalid_grant} ->
        {:ok, %{__jido_watch__: %{plugin_state | connection: :unconnected}}}

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp with_retry(fun, delay_ms, attempt \\ 1) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if transient?(reason) and attempt < @max_attempts do
          Process.sleep(delay_ms)
          with_retry(fun, delay_ms, attempt + 1)
        else
          err
        end
    end
  end

  defp transient?({:trakt_status, status, _}) when status >= 500, do: true
  defp transient?(%{__exception__: true}), do: true
  defp transient?(_), do: false

  defp run_pipeline(plugin_state, %{access_token: access_token}, agent) do
    Watching.run(%{
      trakt: plugin_state.trakt,
      subtitles: plugin_state.subtitles,
      access_token: access_token,
      host: agent.agent_module,
      agent: agent,
      angles: plugin_state.angles,
      watermark: plugin_state.watermark
    })
  end
end
