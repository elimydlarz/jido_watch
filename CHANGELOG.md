# Changelog

All notable changes to `:jido_watch` are recorded here. Each entry covers what
shipped to Hex under that version.

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
