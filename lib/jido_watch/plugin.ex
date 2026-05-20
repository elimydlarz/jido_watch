defmodule JidoWatch.Plugin do
  @moduledoc """
  Jido plugin that turns a Jido agent into a viewer.

  Owns: OAuth state machine, Trakt polling, the watching pipeline.
  Never owns: LLM calls, prompts, memory access, message delivery.
  """

  alias JidoWatch.Actions.PollWatches
  alias JidoWatch.Actions.UserSetup
  alias JidoWatch.Poller

  use Jido.Plugin,
    name: "jido_watch",
    state_key: :__jido_watch__,
    actions: [UserSetup, PollWatches],
    signal_routes: [
      {"user_setup", UserSetup},
      {"poll", PollWatches}
    ]

  @impl Jido.Plugin
  def mount(agent, _config) do
    existing = Map.get(agent.state, :__jido_watch__, %{})

    defaults = %{
      trakt: nil,
      subtitles: nil,
      trakt_client_id: nil,
      trakt_client_secret: nil,
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      angles: [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads],
      connection: :unconnected,
      watermark: nil,
      last_setup_url: nil,
      last_setup_error: nil,
      poll_interval_minutes: nil
    }

    {:ok, Map.merge(defaults, existing)}
  end

  @impl Jido.Plugin
  def child_spec(_config) do
    agent_pid = self()

    %{
      id: Poller,
      start: {Poller, :start_link, [[agent_pid: agent_pid]]}
    }
  end
end
