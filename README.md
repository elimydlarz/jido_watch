# jido_watch

A behaviour and Jido plugin that turns a Jido agent into a viewer. The agent
watches what the user watches — episode by episode, ten minutes at a time —
and forms its own opinion about each one, informed by whatever it remembers
about the user and their other shows. The opinion is delivered by the agent
itself, in its own voice, through its own channel.

`jido_watch` owns the *mechanism*: polling Trakt, OAuth, fetching subtitles,
slicing cues into attention windows, looping callbacks in the right order.
The host agent owns the *inference*: every LLM call, every prompt, every
memory query, every word the user reads.

See [`VISION.md`](VISION.md) for the product framing,
[`CLAUDE.md`](CLAUDE.md) for the implementation mental model, and
[`TEST_TREES.md`](TEST_TREES.md) for the behaviour contract.

## Installation

```elixir
def deps do
  [
    {:jido_watch, "~> 0.1"}
  ]
end
```

## Wiring it into a Jido agent

Three things make a Jido agent into a viewer:

1. Mount `JidoWatch.Plugin` in the agent's `plugins:` list.
2. Declare `@behaviour JidoWatch` and implement `watch/2`, `experience/3`,
   `form_opinion/2`.
3. Configure the Trakt client and subtitle source in the agent's initial
   state under the `:__jido_watch__` plugin-state slot.

```elixir
defmodule MyApp.ViewerAgent do
  use Jido.Agent,
    name: "my_viewer",
    plugins: [JidoWatch.Plugin]

  @behaviour JidoWatch

  alias JidoWatch.Experience
  alias JidoWatch.Impression

  @impl JidoWatch
  def watch(agent, chunk) do
    # agent.state has your LLM client, memory backend, voice config — read
    # what you need from it, do whatever inference you want, return an
    # Experience that summarises what this 10-minute window meant.
    {:ok, %Experience{chunk: chunk, data: my_llm_take_on(agent, chunk)}}
  end

  @impl JidoWatch
  def experience(agent, experiences, angle) do
    # One impression per configured angle, reading every experience through
    # that angle's lens. Plugin runs all angles in parallel.
    {:ok, %Impression{angle: angle, data: my_llm_impression(agent, experiences, angle)}}
  end

  @impl JidoWatch
  def form_opinion(agent, impressions) do
    # Terminal. Integrate the per-angle impressions, compose a message in
    # your agent's voice, and deliver it however your agent normally delivers
    # messages (Telegram, web, voice, whatever).
    deliver(agent, my_llm_compose(agent, impressions))
    :ok
  end
end
```

The callbacks receive the `%Jido.Agent{}` struct, not a server pid, so a
callback can read `agent.state` directly for any clients or configuration
the host stashed there.

## The `user_setup` action

The plugin exposes one LLM-callable action your agent's LLM should be told
about: `user_setup`. The LLM decides *when* in a conversation to
bring up Trakt connection.

- Called with no args, returns a Trakt authorization URL. The LLM weaves
  the URL into a reply in its own voice.
- Called with `code: "<the code Trakt gave the user>"`, exchanges the code
  for tokens. From that point on, the plugin can poll for new watches.

The action is registered with Jido under the signal type
`jido_watch.user_setup`. Wire it into your agent's tool surface so
the LLM can call it directly.

## Configuration

Pass Trakt and subtitle wiring through plugin config at the `use Jido.Agent`
site. Plugin config is per agent module (compile-time); per-user data like
OAuth tokens lives in plugin state and is set at runtime via `user_setup`.

```elixir
defmodule MyApp.ViewerAgent do
  use Jido.Agent,
    name: "my_viewer",
    plugins: [
      {JidoWatch.Plugin,
       %{
         trakt: {JidoWatch.Trakt.HTTP, JidoWatch.Trakt.HTTP.new(
           client_id: System.fetch_env!("TRAKT_CLIENT_ID"),
           client_secret: System.fetch_env!("TRAKT_CLIENT_SECRET")
         )},
         subtitles: {MyApp.MySubtitleSource, my_handle},
         trakt_client_id: System.fetch_env!("TRAKT_CLIENT_ID"),
         trakt_client_secret: System.fetch_env!("TRAKT_CLIENT_SECRET"),
         angles: [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads],
         poll_interval_minutes: 60
       }}
    ]
end
```

The `:trakt` and `:subtitles` values are `{module, handle}` pairs — the
module implements the `JidoWatch.Trakt.Client` and `JidoWatch.Subtitle.Source`
behaviours respectively. `JidoWatch.Trakt.HTTP` is the bundled real client.

`:poll_interval_minutes` controls how often the plugin polls Trakt for new
watches. Polling is gated by auth — no ticks fire until a user is connected
via `user_setup`, at which point polls begin on the configured cadence and
continue for the lifetime of the agent. Defaults to 60 if omitted.

## Persistence

The plugin participates in Jido's checkpoint/thaw protocol. Three per-user
cursors are durable across a hibernate/thaw round-trip:

- `connection` — the OAuth tokens granted by `user_setup`
- `watermark` — the latest Trakt `watched_at` the plugin has already looked past
- `pending_watches` — entries discovered past the watermark whose pipeline run
  hasn't yet produced an opinion (e.g. subtitles weren't available yet)

These are externalized via `on_checkpoint/2` and rehydrated via `on_restore/2`.
Everything else in the plugin slice (adapter handles, OAuth client credentials,
redirect URI, angles, poll interval, setup ephemera) is reseeded from plugin
config on every mount and on every thaw — so a config change between deploys
takes effect immediately, with no stale checkpoint values lingering.

For durability across process restarts, the consuming app must configure the
`Jido.AgentServer` with `Jido.AgentServer.Lifecycle.Keyed` and a durable
`Jido.Storage` adapter (`Jido.Storage.File` or `Jido.Storage.Redis` — not
`Jido.Storage.ETS`, which is ephemeral). With the default `Noop` lifecycle the
plugin runs in memory and a restart loses all three cursors: the user must
re-authorize, the polling watermark resets, and any unfinished retries in
`pending_watches` are dropped.

## Default angles

The angles are the product surface — change them and you change what kind
of viewer the agent becomes. Defaults ship with the package:

1. `:emerging_themes` — what the episode was quietly *about*, beyond plot
2. `:character_readings` — who showed something new of themselves, who's drifting
3. `:cross_show_rhymes` — what in the viewer's other shows just got echoed
4. `:loose_threads` — what the agent is left wondering, what they want to ask the user

Override the list by setting `:angles` in plugin state at startup.

## What's in the box

- The `JidoWatch` behaviour with three callbacks.
- `%JidoWatch.Chunk{}`, `%JidoWatch.Experience{}`, `%JidoWatch.Impression{}`,
  `%JidoWatch.Subtitle.Cue{}`.
- `JidoWatch.Plugin` — the Jido plugin that mounts the watching apparatus.
- `JidoWatch.Actions.UserSetup` — the LLM-callable OAuth action.
- `JidoWatch.Actions.PollWatches` — one tick of the watching pipeline,
  invoked by signal `jido_watch.poll`.
- `JidoWatch.Poller` — internal periodic process started under the agent's
  supervisor; emits the `jido_watch.poll` signal on the configured cadence
  once a user is connected.
- `JidoWatch.Trakt.HTTP` — real Trakt API client.
- `JidoWatch.Subtitle.Source` — driven port for fetching subtitle cues.

## Invariants worth knowing

- **Polling is gated by auth.** No tokens, no polling. `user_setup`
  is the only path to enabling watching.
- **Transcript-or-nothing.** Watches without subtitle content produce no
  opinion. Episode metadata alone is hollow.
- **Sequential chunks, parallel angles.** Chunk N+1 doesn't start until
  chunk N's `watch/2` returns. All angle `experience/3` calls run in
  parallel; `form_opinion/2` waits on all of them.
- **No partial opinions.** If any callback in the pipeline returns an
  error, the whole watch fails — no opinion is delivered.
- **The plugin never sees the LLM, the system prompt, the memory backend,
  or the delivery channel.** All four live entirely on the agent side of
  the boundary.

## Licence

MIT.
