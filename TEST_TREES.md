# Test Trees

## System

Trees here describe top-level, user-facing behaviour. Tests run against a real `Jido.AgentServer` with `JidoWatch.Plugin` mounted on a fixture host agent that implements `@behaviour JidoWatch` with canned callback bodies. Only the LLM (which would otherwise be called inside the host agent's callbacks) and the external infrastructure (Trakt API, subtitle source) are stubbed via in-memory twins — the plugin code path and the Jido runtime are real.

### watching

```
watching (system: test/system/watching_test.exs)
  when the user watches new content
    then the agent's watch/2 is called once per chunk
    then the agent's experience/3 is called once per angle, with the experiences from watch
    then the agent's form_opinion/2 is called once with the impressions from each angle
  when the user has not watched anything new
    then no callbacks are called
  when content the user watched cannot be processed
    then form_opinion/2 is not called
  when the same entry appears in a subsequent poll
    then the agent's callbacks are not invoked again for it
```

### polling

The plugin owns Trakt polling — once a user is connected, polls fire on a
cadence for the lifetime of the agent. Nothing external schedules them.
Polling is gated by auth (CLAUDE.md): no ticks fire while unconnected; they
begin on the connection transition and die with the agent. The cadence is
configurable per agent via `:poll_interval_minutes` in plugin state.

```
polling (system: test/system/polling_test.exs)
  when the plugin is mounted with no user connected
    then no polls fire
    when the user becomes connected via user_setup
      then polls begin firing on the configured interval
      then they continue for as long as the agent runs
  when the plugin is mounted with the user already connected
    then polls begin firing on the configured interval
  when the plugin mounts with a custom :poll_interval_minutes in plugin state
    then polls fire on that interval rather than the default
  when the agent terminates
    then polling stops
```

### journey

The functional-realism System test: the same `JidoWatch.Plugin` driven by the
same `Jido.AgentServer` signal API as the hermetic system tests, wired to the
real `Trakt.HTTP` and `Subtitle.OpenSubtitles` adapters. The test exercises
the **whole runtime lifecycle**: app startup logs into OpenSubtitles to obtain
a bearer, `user_setup` produces a Trakt authorization URL, the developer
(playing the user) authorizes and pastes the resulting code, the agent polls,
and the pipeline runs. Excluded from the default test run; opt in via
`mix test.journey`.

**Precondition:** `.env` must contain the static credentials listed in
`.env.example` (Trakt client id/secret, OpenSubtitles api key/username/password/user_agent).
If anything is missing, the test fails fast with a message naming the variable;
no fallbacks.

```
journey (system: test/system/journey_test.exs)
  when the user requests Trakt authorization through user_setup
    then an authorization URL is returned
      when the user authorizes on Trakt and submits the resulting code through user_setup
        then the agent becomes connected
          when the agent polls Trakt for the connected user
            when there are new entries past the watermark
              when the most recent entry's subtitles can be fetched from OpenSubtitles
                then the agent's watch/2 is invoked
                then experience/3 is invoked once per configured angle
                then form_opinion/2 is invoked once
                  when the agent polls again
                    then no callbacks fire for the entry already processed
              when the most recent entry's subtitles cannot be fetched from OpenSubtitles
                then no callbacks fire
            when there are no new entries past the watermark
              then no callbacks fire
```

### user_setup

```
user_setup (system: test/system/user_setup_test.exs)
  when the agent calls the user_setup action for an unconnected user
    then an authorization URL is returned
  when called with a valid auth code for that user
    then the user becomes connected
    then subsequent polling only processes watches recorded after this moment
  when called with an invalid code
    then the user does not become connected
  when a user is not connected
    then no watching happens for them
```

## Use-case

Trees here describe the watching pipeline orchestration in isolation. Tests
call the pipeline module directly with in-memory Trakt and subtitle adapters,
and a recording host fixture that implements `@behaviour JidoWatch`. No
`Jido.AgentServer`, no signal routing — just the orchestration logic.

### Watching

```
Watching (use_case: test/use_case/watching_test.exs)
  run/1
    when there are new watch entries with fetchable subtitles
      then watch/2 is called once per chunk in window order
    when an entry's watched_at is no later than the watermark
      then it is skipped
    then the returned watermark is the maximum of the input watermark and every attempted entry's watched_at
```

Error variants (no new entries, unfetchable subtitles) are covered by the
`watching` system tree rather than re-asserted here; their value is at the
seam where the action meets the agent runtime, not in the pure pipeline.

### User_setup

```
User_setup (use_case: test/use_case/user_setup_test.exs)
  run/2
    when called with no code
      then last_setup_url is set to a Trakt authorize URL carrying the client_id and redirect_uri
      then connection stays :unconnected
    when called with a valid code
      then connection becomes {:connected, tokens} from Trakt
      then last_setup_error is cleared
      then the watermark is set to a DateTime no earlier than the moment of exchange
    if Trakt rejects the code
      then connection stays :unconnected
      then last_setup_error is set to the reason Trakt returned
```

## Domain

Trees here describe pure functions over the domain types — chunking cues into
attention windows. No collaborators, no I/O.

### Chunker

```
Chunker (domain: test/domain/chunker_test.exs)
  chunk_for_watch/2
    then a cue is placed in the chunk whose 10-minute window contains its start_ms
    then cues falling in the same window appear in the same chunk
    then chunks are returned in window order
    then each chunk's index reflects its window number from zero
    then windows containing no cues do not appear in the output
    then each chunk carries the source watch entry
    when given no cues
      then no chunks are returned
```

### Srt

```
Srt (domain: test/domain/srt_test.exs)
  parse/1
    then each block becomes a Cue with start_ms and end_ms parsed from the timestamp line
    then multi-line cue text is joined with newlines
    then blocks separated by extra blank lines parse the same as single-blank-separated
    when given an empty string
      then no cues are returned
    if a block has a malformed timestamp line
      then the error wraps the offending block index
```

## Adapter

Trees here describe the real driven adapters that talk to external infrastructure.
Tests run against the real adapter module with HTTP responses provided by
`Req.Test`'s plug stub — the request shape and response mapping are real; the
network is not. The same module is also exercised end-to-end against the live
Trakt API by the `journey` system test, which keeps the human
authorization step in the loop via `user_setup`.

### Subtitle.OpenSubtitles

```
Subtitle.OpenSubtitles (adapter: test/adapter/subtitle_open_subtitles_test.exs)
  fetch/2
    when the watch entry is a movie with an imdb_id
      then it searches OpenSubtitles by imdb_id with the Api-Key and User-Agent headers
      then it returns the parsed cues from the SRT linked via /download
    when the watch entry is an episode with an imdb_id
      then it searches by the episode's imdb_id
    when the handle carries a bearer_token
      then /download is sent with Authorization: Bearer <token>
    if the search returns no subtitles
      then the error is :no_subtitles
    if /subtitles responds non-200
      then the error wraps the status and body
    if /download responds non-200
      then the error wraps the status and body
    if the SRT URL responds non-200
      then the error wraps the status and body
  login/3
    when given valid credentials
      then it POSTs username and password to /login and returns the bearer token from the response
    if /login responds non-200
      then the error wraps the status and body
```

### Trakt.HTTP

```
Trakt.HTTP (adapter: test/adapter/trakt_http_test.exs)
  exchange_code/2
    when given a valid auth code
      then it POSTs the code with client credentials and grant_type to /oauth/token
        and returns the parsed access_token, refresh_token and expires_in
    if Trakt responds with a non-200 status
      then the error wraps the status and body
  recent_watches/2
    when given a valid access token
      then it GETs /sync/history with bearer auth, trakt-api-version and trakt-api-key headers
        and returns the parsed list of entries
    if Trakt responds with a non-200 status
      then the error wraps the status and body
```
