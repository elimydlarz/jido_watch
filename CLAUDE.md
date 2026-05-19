# jido_watch

A Jido plugin + behaviour that turns a Jido agent into a viewer: polls a media feed (Trakt today), runs new watches through a transcript-chunking pipeline, and produces structured opinions the agent delivers to the user in its own voice.

`VISION.md` carries the product framing. This file carries the implementation mental model — read it first when touching anything in here.

## Mental Model

### The boundary

The central invariant: **plugin owns mechanism, agent owns inference and conversation.**

| Concern | Side |
|---|---|
| OAuth state machine, URL generation, token exchange and storage, expiry | plugin |
| Polling Trakt, watermark management, transcript fetching | plugin |
| Chunking transcripts, looping callbacks in sequence, accumulating experiences and impressions, calling form_opinion | plugin |
| All LLM calls, all prompt engineering, system-prompt voice | agent |
| Memory backend and how to search it | agent |
| Recognising a code-shaped paste in a user message | agent |
| Deciding *when* to offer Trakt connection in conversation | agent |
| Delivering the opinion to the user (Telegram, web, voice, whatever) | agent |

These lines never blur: the plugin never writes a prompt, never calls an LLM, never queries memory. The agent never holds OAuth state, never runs a poll loop, never owns the chunk-by-chunk pipeline. When you're tempted to break this, you're probably wrong; check the test trees first.

### The interface

Small and bidirectional.

**Agent supplies three callbacks the plugin invokes during the watching pipeline.** All inference happens here.

- `watch(%Jido.Agent{}, %Chunk{}) :: {:ok, %Experience{}}` — turn one transcript chunk into an experience. The agent struct gives the callback access to its own `state` (LLM client, memory backend, voice config) without resolving its server pid; the agent is free to search its memory, call its LLM with whatever prompt, build the experience in whatever shape — as long as it returns one.
- `experience(%Jido.Agent{}, [%Experience{}], angle) :: {:ok, %Impression{}}` — read all the accumulated experiences through a single angle's lens to form an impression.
- `form_opinion(%Jido.Agent{}, [%Impression{}]) :: :ok` — integrate the per-angle impressions, compose a message in the agent's own voice, deliver it however the agent normally delivers messages. **Terminal.** No `on_opinion` afterwards; the agent owns delivery here.

**Plugin exposes one LLM-callable action the agent uses to drive setup.**

- `setup_jido_watch` — called with no args, returns an authorization URL; called with `code: "..."`, exchanges the code for tokens and connects the user. The LLM decides when in the conversation to call it.

### The asymmetry

Watching is **plugin-pushed**: a new watch arrives, the plugin runs the loop, calling into the agent at each step. Mechanical and pre-conditional — there's no judgment about whether to run the pipeline.

Setup is **agent-pulled**: only the agent's LLM knows the right conversational moment to bring up Trakt connection. The plugin makes the capability available via the action and waits. This matches the only place LLM judgment actually adds value — knowing whether the user is in a frame of mind to set things up.

If you find yourself adding a callback the plugin calls during setup, you're crossing the boundary the wrong way; the answer is almost always to expose another argument or another tool the LLM can call, not to push to the agent.

### How the flows play out

**Setup flow.** User chats with the agent. The agent's LLM, prompted to offer Trakt connection when relevant, decides this is the moment and calls `setup_jido_watch`. Tool returns a URL. The LLM weaves it into a reply in its own voice. The user authorizes out of band on Trakt, gets a code, pastes it back. The LLM recognises the code in the user message and calls `setup_jido_watch(code: "...")`. Tool exchanges, marks the user connected. LLM confirms in conversation. The plugin now polls.

**Watching flow.** Trakt poll discovers a new entry past the watermark for a connected user. Plugin fetches subtitles. Plugin slices cues into 10-minute attention windows. For each chunk in order, plugin calls `agent.watch(chunk)` and collects the experience. Once all chunks are processed, plugin calls `agent.experience(experiences, angle)` once per configured angle in parallel and collects the impressions. Plugin calls `agent.form_opinion(impressions)`. Agent composes its message and delivers it.

### Invariants

- **Polling is gated by auth.** No tokens for a user, no polling for that user. The `setup_jido_watch` action is the only path to enabling watching.
- **Transcript-or-nothing.** Watches without subtitle content produce no opinion. Episode metadata alone is hollow.
- **Sequential chunks, parallel angles.** Chunk N+1 doesn't start until chunk N's `watch/2` returns. All angle `experience/3` calls run in parallel; `form_opinion/2` waits on all of them.
- **No partial opinions.** If any callback in the pipeline returns an error, the whole watch fails — we don't deliver an opinion built from partial inputs.
- **The plugin never sees the LLM, the system prompt, the memory backend, or the delivery channel.** If a change requires it to, the change is in the wrong place.

## Dependencies

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`
- HTTP client (`{:req, "~> 0.5"}`) — Trakt + subtitle source

No dep on `:jido_gralkor` or any specific memory backend. The agent supplies its own memory access inside `watch/2`.

## Default angles

Ship with the package, override via plugin config:

1. **Emerging themes** — what this episode was quietly *about*, beyond plot
2. **Character readings** — who showed something new of themselves, who's drifting
3. **Cross-show rhymes** — what in the viewer's other shows just got echoed
4. **Loose threads** — what the agent is left wondering, what they'd want to ask the user

The angles are the product surface. Change them and you change what kind of viewer the agent becomes.

## Testing

Four layers, named for the hex seam under test, not for infrastructure presence:

| Layer | What it covers | Location | Tag |
|---|---|---|---|
| Domain | Pure domain structs and functions (chunk, experience, impression, opinion). No collaborators. | `test/domain/` | `@moduletag :domain` |
| Use-case | The watching pipeline orchestration, exercised against a fixture host agent that implements the three callbacks with canned data. The OAuth state machine. | `test/use_case/` | `@moduletag :use_case` |
| Adapter | The Trakt HTTP adapter against its port contract; the subtitle fetcher adapter. Driving: mock the use-case. Driven: real HTTP (recorded/replayed). | `test/adapter/` | `@moduletag :adapter` |
| System | Real `Jido.AgentServer` running a fixture host agent that mounts the real `JidoWatch.Plugin` and implements `@behaviour JidoWatch` with canned callback bodies. The plugin code path and the Jido runtime are always real. **Driven adapters in two modes:** in-memory twins by default (`mix test.system`), real Trakt + real OpenSubtitles for the functional-realism journey (`mix test.journey`, opt-in via `.env`). | `test/system/` | `@moduletag :system` (default), `@moduletag :journey` (functional) |

Every test module declares the moduletag matching its directory. The per-layer mix aliases use `--only <tag>` for filtering (works correctly on empty suites; directory paths don't).

Commands:

```bash
mix test                # all layers, journey excluded
mix test.domain         # test/domain only
mix test.use_case       # test/use_case only
mix test.adapter        # test/adapter only
mix test.system         # test/system only (hermetic)
mix test.journey        # functional journey vs real Trakt + OpenSubtitles
mix test.stale          # only tests affected by recent changes
mix test --failed       # re-run previously failed tests
```

ExUnit's `trace: true` is set in `test/test_helper.exs` — output is flat by language design (no nested `describe` in ExUnit), but each module and test name is printed. `:junit_formatter` emits `_build/test/junit/junit.xml` when `CI=true`.

No mutation testing: no mature Elixir tool exists (Muzak and Exavier are unmaintained). `:stream_data` is included for property-based testing where confidence-via-cases matters.

Architectural enforcement (plugin owns mechanism, agent owns inference — see *The boundary* above) is currently a discipline, not a linter. If it drifts, install `:boundary` and declare `JidoWatch.Plugin` / `JidoWatch.Trakt.*` / `JidoWatch.Poller` as inward-facing modules that cannot import `JidoWatch.Behaviour`-related code that calls LLMs or memory.

## Mental Model

See [MENTAL_MODEL.md](MENTAL_MODEL.md).

## Test Trees

See [TEST_TREES.md](TEST_TREES.md).
