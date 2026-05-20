## Core Domain Identity

What this project is and is not, in one sentence — the irreducible essence of `jido_watch`.

## World-to-Code Mapping

How real-world entities (a watch, a transcript chunk, an experience, an impression, an opinion, a user-being-connected) correspond to code structures.

## Ubiquitous Language

Canonical terms used in code, tests, and docs — and what they specifically mean here (`watch`, `chunk`, `experience`, `impression`, `opinion`, `user_setup`, `host agent`, `consuming agent`, `operator`, `user`).

## Bounded Contexts

The boundary between the plugin (mechanism) and the consuming agent (inference and conversation) — what's where and why.

**Setup is split between two principals.** The *operator* configures static credentials in `.env` once (Trakt client id/secret, OpenSubtitles api key/username/password/user_agent); the consuming app reads these at startup and obtains its runtime tokens programmatically (e.g. OpenSubtitles bearer via `OpenSubtitles.login/3`). The *user* authorizes Trakt at runtime through the `user_setup` action — the LLM offers a URL, the user authorizes, the LLM exchanges the resulting code. The package ships exactly one entry point for each: `user_setup` for the user-driven half; static config + at-startup login for the operator-driven half. No mix commands wrap user-side OAuth.

## Invariants

The properties that must always hold across the system (auth gates polling, transcript-or-nothing, sequential chunks parallel angles, no partial opinions, the plugin never sees the LLM or memory backend).

## Decision Rationale

The non-obvious choices and what they trade against (single behaviour module rather than a separate library, agent-pulled setup vs plugin-pushed watching, terminal `form_opinion/2` instead of a separate delivery callback).

**Plugin state is the action result channel.** `Jido.AgentServer.call/3` returns `{:ok, agent}` regardless of whether the action returned `{:ok, state_updates}` or `{:error, reason}` — error tuples are absorbed by `ErrorPolicy` (logged by default) and never reach the caller. The action's only way to communicate outcomes (success *or* failure) is by writing into its plugin state slice. So `JidoWatch.Plugin` carries `:connection`, `:last_setup_url`, and `:last_setup_error` as deliberate result fields; helpers and the LLM tool wrapper read them back after the call. New actions should follow this — return `{:ok, %{__jido_watch__: ...}}` for both branches rather than `{:error, ...}` upward.

**Callbacks receive the agent struct, not its server pid.** `watch/2`, `experience/3`, and `form_opinion/2` all take `%Jido.Agent{}` as the first argument. Jido runs actions in a Task spawned by the AgentServer, and the AgentServer pid is not exposed through the action context — the `:agent_server_pid` field in the action context is the Task pid, not the server. Passing the struct sidesteps the lookup entirely: the host reads `agent.state` directly for its LLM client, memory backend, and voice config without resolving its server through the registry. The trade is that callbacks cannot send signals back to the server from inside themselves; they shape data and return it, which matches the pipeline's expectation that inference is a pure transformation per chunk/angle.

**The journey test is the functional-realism System test, not a separate layer.** Per Contree, System tests are "whole wired app, in-memory driven adapters by default; real on demand." The hermetic system tests (`mix test.system`) run with in-memory Trakt and subtitle twins; the journey test (`mix test.journey`) reuses the same `Jido.AgentServer` + plugin + signal-driving surface but wires real `Trakt.HTTP` and real `Subtitle.OpenSubtitles`, and walks the whole runtime lifecycle — OpenSubtitles login at startup, `user_setup` interactive OAuth, polling, callback invocations. Operator-side setup is `.env` and nothing else; if it's incomplete the journey fails fast with the missing variable named, no fallbacks.

## Temporal View

Lifecycle of a watch from poll to delivered opinion; lifecycle of a user from unconnected to connected via `user_setup`.
