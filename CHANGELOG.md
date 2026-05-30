# Changelog

All notable changes to `:jido_watch` are recorded here. Each entry covers what
shipped to Hex under that version.

## 1.1.0 — 2026-05-30

### Behaviour and plugin
- `user_setup(code: "...")` now returns a `%JidoWatch.ViewingProfile{}` of the
  user's Trakt backlog as the ephemeral `:last_setup_profile` result field —
  facts only (watched-show/movie counts, genre tally, play-ranked shows, recent
  history, ratings histogram), built once at connection time. The agent reads it
  for taste; the plugin makes no judgments. Lets the agent open with what the
  user has actually been watching.
- `user_setup` accepts a ReAct-style context shape, so agents driving it through
  a ReAct tool loop no longer have to reshape the call.

### Configuration
- Adapters can now be supplied as **primitives** instead of pre-built
  `{module, handle}` tuples: `trakt_adapter` + `trakt_client_id` +
  `trakt_client_secret`, and `subtitle_adapter` + `opensubtitles_api_key` +
  `opensubtitles_user_agent` (+ optional `username`/`password`). The plugin
  constructs the handles at mount time, so consuming apps avoid compile-time
  module loading. The pre-built tuple form still works (used by tests).
- When the subtitle adapter is `JidoWatch.Subtitle.OpenSubtitles`, the plugin
  reads a pre-authenticated bearer token from the operator setup file and the
  adapter re-logs-in on 401.

### Operator tooling
- `mix jido_watch.operator_setup` — one-time operator task that validates Trakt
  and OpenSubtitles credentials and persists an OpenSubtitles bearer token
  (`JidoWatch.SetupPersistence`) for the plugin to pick up at mount.

## 1.0.0 — 2026-05-22

Initial public release on Hex (`susu` organisation).

### Behaviour and plugin
- `JidoWatch` behaviour with three callbacks the host agent implements:
  `watch/2` (chunk → experience), `experience/3` (experiences + angle →
  impression), `form_opinion/2` (impressions → terminal delivery).
- `JidoWatch.Plugin` — Jido plugin owning the `:__jido_watch__` agent-state
  slot. Mounts polling, hydrates per-user cursors on thaw, runs the watching
  pipeline. `connection`, `watermark`, and `pending_watches` survive
  `Jido.Persist` round-trips; the rest reconstitutes from plugin config.

### Watching pipeline
- `JidoWatch.Chunker` slices subtitle cues into 10-minute attention windows.
- `JidoWatch.Watching` orchestrates: sequential `watch/2` calls per chunk,
  parallel `experience/3` calls across configured angles, single
  `form_opinion/2` once all impressions are in. No partial opinions on
  callback error.
- `JidoWatch.Poller` walks the Trakt feed past each connected user's
  watermark, fetches transcripts, drives the pipeline. Polling is gated by
  auth — no tokens, no polling for that user.
- Default angles ship with the package: *emerging themes*, *character
  readings*, *cross-show rhymes*, *loose threads*. Overridable via plugin
  config.

### OAuth and adapters
- `JidoWatch.Actions.UserSetup` — agent-pulled OAuth tool. The host's LLM
  calls it (no args → returns authorization URL; `code: "..."` → exchanges
  for tokens and connects the user). The plugin never decides when to offer
  connection; the agent does.
- `JidoWatch.Trakt.Client` + `JidoWatch.Trakt.HTTP` — Trakt adapter behind a
  port; in-memory twin used by the default test layer.
- `JidoWatch.Subtitle.Source` + `JidoWatch.Subtitle.OpenSubtitles` — subtitle
  fetching with the same port/twin shape.
- `JidoWatch.Srt` — SRT parser feeding `JidoWatch.Subtitle.Cue` into the
  chunker.

### Domain
- `JidoWatch.Chunk`, `JidoWatch.Experience`, `JidoWatch.Impression`,
  `JidoWatch.Watching.Opinion` — pure structs that flow through the
  pipeline.

### Testing
- Four layers: `test/domain`, `test/use_case`, `test/adapter`, `test/system`
  (hermetic) + `test/journey` (real Trakt + OpenSubtitles, opt-in). Tagged
  by directory, driven by `mix test.<layer>` aliases.
