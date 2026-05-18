## Core Domain Identity

What this project is and is not, in one sentence — the irreducible essence of `jido_watch`.

## World-to-Code Mapping

How real-world entities (a watch, a transcript chunk, an experience, an impression, an opinion, a user-being-connected) correspond to code structures.

## Ubiquitous Language

Canonical terms used in code, tests, and docs — and what they specifically mean here (`watch`, `chunk`, `experience`, `impression`, `opinion`, `setup_jido_watch`, `host agent`, `consuming agent`).

## Bounded Contexts

The boundary between the plugin (mechanism) and the consuming agent (inference and conversation) — what's where and why.

## Invariants

The properties that must always hold across the system (auth gates polling, transcript-or-nothing, sequential chunks parallel angles, no partial opinions, the plugin never sees the LLM or memory backend).

## Decision Rationale

The non-obvious choices and what they trade against (single behaviour module rather than a separate library, agent-pulled setup vs plugin-pushed watching, terminal `form_opinion/2` instead of a separate delivery callback).

## Temporal View

Lifecycle of a watch from poll to delivered opinion; lifecycle of a user from unconnected to connected via `setup_jido_watch`.
