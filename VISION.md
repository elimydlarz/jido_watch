# jido_watch — Vision

## What it is

`jido_watch` turns a Jido agent into a viewer. The agent watches what you watch — episode by episode, ten minutes at a time — and forms its own opinion about it, informed by everything it remembers about you and your other shows. Then it says something. That "something" is the point.

This is for people who finish an episode and want to think out loud with someone who saw it. Not a podcaster talking past you; not a Reddit thread you have to dig through; not a friend who's three seasons behind. An agent who watched it with you, brings its own perspective, remembers what you watched last month, and starts a real conversation about what just happened.

## Why it exists

Parasocial podcast-listening fills a real gap: you want to think with someone about the thing you just watched, and you can't always find that person in your life. Existing options don't actually engage with *your* watching — they're broadcasts. `jido_watch` is the opposite: the agent watches your shows, has its own evolving experience of them all at once, and the conversation is between two viewers — one of whom happens to be infrastructure.

No spoiler problem. The agent only knows what you've shown it; it can't get ahead of you. Cross-show recall is the whole point — the agent says "this scene rhymes with what happened in Beef, did you feel that?" and that connection is yours together.

## Shape

`jido_watch` is a behaviour for an agent, not a library that does work behind the scenes.

The host agent — whatever it is, whoever wrote it, whatever its memory or voice — declares `@behaviour JidoWatch` and implements three callbacks. `jido_watch` orchestrates the watching loop, calls into the agent's callbacks at each stage, and steps back; the agent supplies all the inference, controls its own memory and voice, and decides what to do with the finished opinion.

```elixir
defmodule JidoWatch do
  @callback watch(pid, %Chunk{}) :: {:ok, %Experience{}}
  @callback experience(pid, [%Experience{}], angle) :: {:ok, %Impression{}}
  @callback form_opinion(pid, [%Impression{}]) :: :ok
end
```

`watch/2` is called once per chunk: agent searches its memory however it likes, calls its LLM with whatever prompt and voice it wants, returns an experience. `experience/3` is called once per configured angle, over all the accumulated experiences. `form_opinion/2` is terminal — the agent integrates the per-angle impressions, composes a message in its own voice, and delivers it however it normally delivers messages. There is no separate `on_opinion` step; delivery happens inside `form_opinion`.

What the package ships:

- The `JidoWatch` behaviour
- `%Watch{}`, `%Chunk{}`, `%Experience{}`, `%Impression{}` structs
- `JidoWatch.Plugin` — Jido plugin that mounts the watching apparatus on the host agent
- `JidoWatch.Actions.Watch` — the action that runs one full watch end-to-end (per-chunk loop, per-angle parallelism, terminal form_opinion call)
- `JidoWatch.Actions.SetupJidoWatch` — LLM-callable action that drives OAuth: called bare returns a Trakt authorization URL; called with `code:` exchanges the code for tokens
- `JidoWatch.Poller` — Trakt poller; consumer-supervised per user
- Default angles for impression-formation — overridable

Trakt is the current source. Letterboxd, manual logging, or any other media feed could replace it without touching the behaviour or the action; the package isn't named for the source.

## How a watch happens

```
Trakt entry past watermark
  ↓ fetch subtitles
%Watch{show, episode, cues}
  ↓ slice cues into 10-minute attention windows
chunks
  ↓ for each chunk, in order:
       agent.watch(chunk)  → %Experience{}
experiences
  ↓ for each angle, in parallel:
       agent.experience(experiences, angle)  → %Impression{}
impressions
  ↓ agent.form_opinion(impressions)
agent composes message, delivers, persists to memory however it sees fit
```

The per-chunk and per-angle inference is *inside the agent's head* — not a turn of conversation, and not captured into memory by any chat-capture machinery. Only the outbound message the agent composes inside `form_opinion/2` becomes a real turn of conversation and is captured the way any other conversational turn is.

## The angles

The default angle set defines what kind of viewer `jido_watch` turns the agent into:

1. **Emerging themes** — what the episode was quietly *about*, beyond plot.
2. **Character readings** — who showed something new of themselves, who's drifting.
3. **Cross-show rhymes** — what in the viewer's other shows just got echoed. This is where surfaced memories pay off.
4. **Loose threads** — what the agent is left wondering, what they want to ask the user.

Consumers can override the angle set entirely via plugin config. The angles *are* the product surface — the levers that turn a generic "produce commentary" agent into a specific kind of viewing companion.

## Constraints

- **Memory-agnostic.** `jido_watch` never knows what backs the memory.
- **Voice-agnostic.** `jido_watch` never writes the message the user sees. The agent does, with the opinion as context.
- **Transcript-substantive.** Episode metadata alone is hollow — the agent watches the actual content (subtitles / transcript), not a synopsis. No transcript → no opinion.
- **Sequential per watch.** A 10-minute chunk closes before the next opens. The reaction at minute 30 is shaped by experiences at minutes 0–10 and 10–20.
- **Push, not poll.** The agent reaches out when it has something to say. The user doesn't have to ask.
- **No spoilers, by construction.** The agent only knows what the user has shown it.

## Non-goals

- `jido_watch` does not decide what the user has watched. The source feed (Trakt today) does.
- `jido_watch` does not own delivery. The host agent does.
- `jido_watch` does not own memory. The host agent does.
- `jido_watch` does not decide the agent's voice. The agent's system prompt does.
- `jido_watch` is not Charlotte. Charlotte fused capability, personality, and delivery in one app; `jido_watch` is the capability cleaved out so any Jido agent can be a viewer.

## Open questions

- **Filtering.** Every watch produces an opinion at v1. That will probably be too chatty. Ship, see how it feels, add suppression heuristics (rewatch detection, "nothing worth saying" prompt branch) when needed.
- **Follow-ups.** If the agent pushes an opinion and the user doesn't reply, does the agent ever follow up later? Out of scope for v1.
- **Long-form transcripts.** A 10-chunk episode is O(20+) LLM calls per watch. Real cost in time and money. Instrument early; optimise only if needed.
- **Persistence of in-flight watches.** Mid-watch failure loses the work. Re-poll picks the entry up next cycle. Good enough for v1; revisit if cost makes lost work painful.
