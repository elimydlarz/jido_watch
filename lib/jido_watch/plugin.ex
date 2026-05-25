defmodule JidoWatch.Plugin do
  @moduledoc """
  Jido plugin that turns a Jido agent into a viewer.

  Owns: OAuth state machine, Trakt polling, the watching pipeline.
  Never owns: LLM calls, prompts, memory access, message delivery.

  ## Config

  Adapters can be supplied in two forms:

    1. **Pre-built** — `{module, handle}` tuples (used by tests):
         trakt: {MyTrakt, handle}, subtitles: {MySub, handle}

    2. **Primitives** — the plugin constructs the handles at mount time
       (used by consuming apps to avoid compile-time module loading):
         trakt_adapter: JidoWatch.Trakt.HTTP, trakt_client_id: "...", trakt_client_secret: "..."
         subtitle_adapter: JidoWatch.Subtitle.OpenSubtitles, opensubtitles_api_key: "...", ...

  When the subtitle adapter is `OpenSubtitles`, the plugin reads the operator
  setup file (`JidoWatch.SetupPersistence`) for a pre-authenticated bearer
  token and stores `username`/`password` on the handle so the adapter can
  re-login on 401.

  ## Durability

  Plugin state durability across `Jido.Persist` hibernate/thaw: only
  `connection`, `watermark`, and `pending_watches` survive. Everything else
  in the slice is re-seeded from plugin config on every mount and on every
  thaw.
  """

  alias JidoWatch.Actions.PollWatches
  alias JidoWatch.Actions.UserSetup
  alias JidoWatch.Poller
  alias JidoWatch.SetupPersistence
  alias JidoWatch.Subtitle.OpenSubtitles

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
      trakt: build_trakt(config),
      subtitles: build_subtitles(config),
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

  # -- adapter construction --------------------------------------------------

  defp build_trakt(%{trakt: {_mod, _handle}} = config), do: config.trakt

  defp build_trakt(config) do
    mod = Map.get(config, :trakt_adapter)
    client_id = config[:trakt_client_id]
    secret = config[:trakt_client_secret]

    if mod && client_id && secret do
      {mod, mod.new(client_id: client_id, client_secret: secret)}
    end
  end

  defp build_subtitles(%{subtitles: {_mod, _handle}} = config), do: config.subtitles

  defp build_subtitles(config) do
    mod = Map.get(config, :subtitle_adapter)
    api_key = config[:opensubtitles_api_key]
    user_agent = config[:opensubtitles_user_agent]

    if mod && api_key && user_agent do
      {:ok, setup} = SetupPersistence.read()

      handle =
        mod.new(
          api_key: api_key,
          user_agent: user_agent,
          username: config[:opensubtitles_username],
          password: config[:opensubtitles_password],
          bearer_token: setup["opensubtitles_bearer"],
          setup_file: SetupPersistence.path()
        )

      {mod, handle}
    end
  end
end
