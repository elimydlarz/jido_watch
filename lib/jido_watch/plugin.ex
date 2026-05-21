defmodule JidoWatch.Plugin do
  @moduledoc """
  Jido plugin that turns a Jido agent into a viewer.

  Owns: OAuth state machine, Trakt polling, the watching pipeline.
  Never owns: LLM calls, prompts, memory access, message delivery.

  Plugin state durability across `Jido.Persist` hibernate/thaw: only
  `connection`, `watermark`, and `pending_watches` survive. Everything else
  in the slice is re-seeded from plugin config on every mount and on every
  thaw.
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

  @durable_keys [:connection, :watermark, :pending_watches]

  @default_angles [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads]
  @default_redirect_uri "urn:ietf:wg:oauth:2.0:oob"

  @impl Jido.Plugin
  def mount(agent, config) do
    existing = Map.get(agent.state, :__jido_watch__, %{})
    {:ok, Map.merge(defaults_from_config(config), existing)}
  end

  @impl Jido.Plugin
  def child_spec(_config) do
    agent_pid = self()

    %{
      id: Poller,
      start: {Poller, :start_link, [[agent_pid: agent_pid]]}
    }
  end

  @impl Jido.Plugin
  def on_checkpoint(plugin_state, _ctx) when is_map(plugin_state) do
    pointer = Map.take(plugin_state, @durable_keys)
    {:externalize, :jido_watch, pointer}
  end

  def on_checkpoint(_plugin_state, _ctx), do: :drop

  @impl Jido.Plugin
  def on_restore(pointer, ctx) when is_map(pointer) do
    config = Map.get(ctx, :config, %{})
    {:ok, Map.merge(defaults_from_config(config), pointer)}
  end

  def on_restore(_pointer, _ctx), do: {:ok, nil}

  defp defaults_from_config(config) when is_map(config) do
    %{
      trakt: Map.get(config, :trakt),
      subtitles: Map.get(config, :subtitles),
      trakt_client_id: Map.get(config, :trakt_client_id),
      trakt_client_secret: Map.get(config, :trakt_client_secret),
      redirect_uri: Map.get(config, :redirect_uri, @default_redirect_uri),
      angles: Map.get(config, :angles, @default_angles),
      connection: :unconnected,
      watermark: nil,
      pending_watches: [],
      last_setup_url: nil,
      last_setup_error: nil,
      poll_interval_minutes: Map.get(config, :poll_interval_minutes)
    }
  end

  defp defaults_from_config(_), do: defaults_from_config(%{})
end
