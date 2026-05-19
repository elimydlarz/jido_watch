defmodule JidoWatch.Actions.PollWatches do
  @moduledoc """
  Drives one tick of the watching pipeline: fetches recent watches from Trakt
  via `JidoWatch.Watching.run/1`, which feeds the agent's three callbacks.

  Gated by connection: an agent without Trakt tokens does no Trakt I/O at all.
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

  defp poll_for_connection({:connected, %{access_token: access_token}}, plugin_state, agent) do
    :ok =
      Watching.run(%{
        trakt: plugin_state.trakt,
        subtitles: plugin_state.subtitles,
        access_token: access_token,
        host: agent.agent_module,
        agent: agent,
        angles: plugin_state.angles
      })

    {:ok, %{}}
  end

  defp poll_for_connection(:unconnected, _plugin_state, _agent), do: {:ok, %{}}
end
