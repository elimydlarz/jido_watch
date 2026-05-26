## Core Domain Identity

What this project is and is not, in one sentence — the irreducible essence of `jido_watch`.

## World-to-Code Mapping

How real-world entities (a watch, a transcript chunk, an experience, an impression, an opinion, a viewing profile, a user-being-connected) correspond to code structures.

## Ubiquitous Language

Canonical terms used in code, tests, and docs — and what they specifically mean here (`watch`, `chunk`, `experience`, `impression`, `opinion`, `viewing profile`, `user_setup`, `host agent`, `consuming agent`, `operator`, `user`).

## Bounded Contexts

The boundary between the plugin (mechanism) and the consuming agent (inference and conversation) — what's where and why.

**Setup is split between two principals.** The *operator* runs `mix jido_watch.operator_setup` once to validate Trakt + OpenSubtitles credentials and persist an OpenSubtitles bearer token to `~/.jido_watch/setup.json`. The *user* authorizes Trakt at runtime through the `user_setup` action — the LLM offers a URL, the user authorizes, the LLM exchanges the resulting code. The package ships exactly one entry point for each: `mix jido_watch.operator_setup` for the operator-driven half; `user_setup` for the user-driven half. The consuming app never calls `OpenSubtitles.login/3` directly — the plugin reads the persisted bearer at mount/restore, and the adapter re-logins on 401 using credentials stored on its handle.

**Consuming apps configure adapters as primitives, not handles.** Since plugin config is read at compile time by `Jido.Plugin` (before adapter modules are loaded), consuming apps pass module atoms and credential strings rather than `{module, handle}` tuples:

    trakt_adapter: JidoWatch.Trakt.HTTP,
    trakt_client_id: "...", trakt_client_secret: "...",
    subtitle_adapter: JidoWatch.Subtitle.OpenSubtitles,
    opensubtitles_api_key: "...", opensubtitles_user_agent: "...",
    opensubtitles_username: "...", opensubtitles_password: "..."

The plugin constructs the adapter handle at mount time via `module.new/1`, reads the persisted bearer from `JidoWatch.SetupPersistence`, and stores `username`/`password` on the handle so the adapter can re-login on 401 without operator involvement. Tests still pass pre-built `{module, handle}` tuples — the plugin detects them and uses them as-is.

## Invariants

The properties that must always hold across the system (auth gates polling, transcript-or-nothing, sequential chunks parallel angles, no partial opinions, the plugin never sees the LLM or memory backend).

## Decision Rationale

The non-obvious choices and what they trade against (single behaviour module rather than a separate library, agent-pulled setup vs plugin-pushed watching, terminal `form_opinion/2` instead of a separate delivery callback).

**Plugin state is the action result channel.** `Jido.AgentServer.call/3` returns `{:ok, agent}` regardless of whether the action returned `{:ok, state_updates}` or `{:error, reason}` — error tuples are absorbed by `ErrorPolicy` (logged by default) and never reach the caller. The action's only way to communicate outcomes (success *or* failure) is by writing into its plugin state slice. So `JidoWatch.Plugin` carries `:connection`, `:last_setup_url`, `:last_setup_error`, and `:last_setup_profile` as deliberate result fields; helpers and the LLM tool wrapper read them back after the call. New actions should follow this — return `{:ok, %{__jido_watch__: ...}}` for both branches rather than `{:error, ...}` upward.

**The connection-time viewing profile is plugin-built facts, returned not pushed.** On a successful `user_setup` code exchange the plugin reads the user's Trakt backlog (`/sync/watched/{shows,movies}` with `extended=full`, `/users/me/stats`, recent history) and returns a `%ViewingProfile{}` — counts, a genre tally, play-ranked shows, a ratings histogram — as the ephemeral `:last_setup_profile` result field. It is the one place the otherwise-discarded pre-watermark backlog surfaces: a one-shot snapshot at connect, while the watermark still governs the forward pipeline unchanged. Two lines hold. It carries facts, never a reading of taste — characterizing the viewer is the agent's inference, so the plugin stays LLM-free. And it is non-fatal: if the backlog fetch fails after the code is accepted, the user stays connected with the watermark set and the profile comes back `nil`, because an enrichment step must not un-connect a connected user. Returning it from the tool rather than a new plugin-called setup callback keeps setup agent-pulled.

**Callbacks receive the agent struct, not its server pid.** `watch/2`, `experience/3`, and `form_opinion/2` all take `%Jido.Agent{}` as the first argument. Jido runs actions in a Task spawned by the AgentServer, and the AgentServer pid is not exposed through the action context — the `:agent_server_pid` field in the action context is the Task pid, not the server. Passing the struct sidesteps the lookup entirely: the host reads `agent.state` directly for its LLM client, memory backend, and voice config without resolving its server through the registry. The trade is that callbacks cannot send signals back to the server from inside themselves; they shape data and return it, which matches the pipeline's expectation that inference is a pure transformation per chunk/angle.

**The poller ticks unconditionally and gates per-tick on connection.** `JidoWatch.Poller` runs every `:poll_interval_minutes` for the agent's lifetime; on each tick it reads `agent.state[:__jido_watch__].connection` and casts the `jido_watch.poll` signal only if connected. The alternative — start the timer on the unconnected→connected transition — would force cross-process notification (a registry keyed by agent pid, or `transform_result/3` reaching into the poller) for behaviour that is observationally identical at the consumer's vocabulary: no Trakt I/O, no callbacks fire while unconnected. Reading plugin state once per default 60-minute tick is negligible against that complexity.

**Token refresh is reactive-only and per-process serialised.** Trakt's 401 on a polled request is the only signal we use to refresh; the plugin stores `%{access_token, refresh_token}` with no `expires_at` or `created_at`. The alternative — track expiry, refresh proactively — duplicates state Trakt is the source of truth for and adds clock-skew handling for no observable gain at our cadence. Refresh tokens rotate on every use (Trakt returns a new pair, the old refresh token immediately dies), so writes must be atomic; the per-user AgentServer process naturally serialises refreshes, which rules out concurrent-refresh races without a separate lock. The terminal `invalid_grant` response on `/oauth/token` — the docs lump revoked, reused, and mismatched-redirect-uri causes under one ambiguous body — flips the connection to `:unconnected` and surfaces re-auth through the existing `user_setup` action; there is no separate reconnect path.

**The watching pipeline is invariant of state.** Each tick does the same thing regardless of what's happened before: fetch from Trakt past the watermark, merge anything new into `pending_watches` (deduped by entry id), attempt every entry on `pending_watches`, drop the ones that produced an opinion. The watermark only tracks "how far back in Trakt's history we've already looked"; per-entry retry is decided by membership in `pending_watches`, not by the watermark. The alternative — gate retry on watermark advancement — couples two orthogonal concerns and forces a branching algorithm whose behaviour depends on which entries succeeded last tick. Decoupling them costs one extra list in plugin state and buys an algorithm with no branches on history: a no-transcript entry stays on the list and is retried next tick (OpenSubtitles indexes new releases asynchronously); a permanently-unavailable entry sits there until the operator prunes it.

**Transient HTTP retry lives in the adapter via Req's `:safe_transient`.** Both `Trakt.HTTP` and `Subtitle.OpenSubtitles` thread `retry: :safe_transient` through every Req call, which retries 408/429/5xx and transport errors with exponential backoff. The use-case layer (`PollWatches`, `Watching`) does not retry — it only handles the 401-refresh-replay dance for Trakt, which can't move down because it needs to mutate plugin-state tokens. The alternative — a use-case-level `with_retry/transient?` wrapper around `Watching.run/1` — conflates "this HTTP call blipped" with "deeper pipeline failure", and reinvents what Req already does. Pushing retry to its source keeps each layer responsible for exactly one failure class.

**The journey test is the functional-realism System test, not a separate layer.** Per Contree, System tests are "whole wired app, in-memory driven adapters by default; real on demand." The hermetic system tests (`mix test.system`) run with in-memory Trakt and subtitle twins; the journey test (`mix test.journey`) reuses the same `Jido.AgentServer` + plugin + signal-driving surface but wires real `Trakt.HTTP` and real `Subtitle.OpenSubtitles`, and walks the whole runtime lifecycle — the host agent constructs OpenSubtitles with a pre-obtained bearer, `user_setup` interactive OAuth, polling, callback invocations. The journey test runs its own login inline rather than through the mix command, since it must run inside the test process, but the production path is `mix jido_watch.operator_setup` → persisted file → plugin reads at mount.

## Temporal View

Lifecycle of a watch from poll to delivered opinion; lifecycle of a user from unconnected to connected via `user_setup`, which on connect also returns a one-time viewing profile of the pre-watermark backlog.
