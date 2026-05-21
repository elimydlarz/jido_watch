# Test Trees

## System

Trees here describe top-level, user-facing behaviour. Tests run against a real `Jido.AgentServer` with `JidoWatch.Plugin` mounted on a fixture host agent that implements `@behaviour JidoWatch` with canned callback bodies. Only the LLM (which would otherwise be called inside the host agent's callbacks) and the external infrastructure (Trakt API, subtitle source) are stubbed via in-memory twins — the plugin code path and the Jido runtime are real.

### watching

```
System: watching (functional: test/system/watching_test.exs)
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
System: polling (functional: test/system/polling_test.exs)
  when the plugin is mounted with no user connected
    then no polls fire
    when the user becomes connected via user_setup
      then polls begin firing on the configured interval
      then they continue for as long as the agent runs
  when the plugin is mounted with the user already connected
    then polls begin firing on the configured interval
  when the plugin mounts with a custom :poll_interval_minutes in plugin state
    then polls fire on that interval rather than the default
  if Trakt errors during a poll
    then the agent does not crash
    then no callbacks fire for that tick
    then the watermark is not advanced
    then polling continues on the next interval
  when Trakt returns 401 for a request during a poll
    then a refresh is attempted with the stored refresh_token
      when the refresh succeeds
        then the new access_token and refresh_token replace the stored pair
        then the original request is retried with the new access_token
        then the tick proceeds normally from there
      if the refresh returns an invalid-grant response
        then the user becomes unconnected
        then no further polls fire for that user
          when the user re-runs user_setup with a valid code
            then polling resumes
  when the agent terminates
    then polling stops
```

Transient HTTP failures (5xx, 408, 429, transport errors) for Trakt requests are
retried inside the `Trakt.HTTP` adapter via Req's `:safe_transient` policy and
fold into the "if Trakt errors during a poll" assertions above once Req gives
up. The use-case layer does not retry.

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
System: journey (functional: test/system/journey_test.exs)
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
System: user_setup (functional: test/system/user_setup_test.exs)
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
Use-case: Watching (src: lib/jido_watch/watching.ex; unit: test/use_case/watching_test.exs)
  run/1
    when there are new watch entries with fetchable subtitles
      then watch/2 is called once per chunk in window order
    when an entry's watched_at is no later than the watermark
      then it is skipped
    when an entry has no transcript available
      then no callbacks fire for it, the watermark still advances past it,
        and it stays on pending_watches for the next tick
    when an entry is already on pending_watches and its transcript is now available
      then it is processed and removed from pending_watches
    when a Trakt entry is already on pending_watches
      then it is not added again
    then the returned watermark is the maximum of the input watermark and every attempted entry's watched_at
```

Error variants (no new entries, unfetchable subtitles) are covered by the
`watching` system tree rather than re-asserted here; their value is at the
seam where the action meets the agent runtime, not in the pure pipeline.

### PollWatches

```
Use-case: PollWatches (src: lib/jido_watch/actions/poll_watches.ex; unit: test/use_case/poll_watches_test.exs)
  run/2
    when the connection is :unconnected
      then no Trakt I/O happens and plugin state is not changed
    when the connection is {:connected, tokens} and the pipeline succeeds
      then the new watermark and pending_watches are written to plugin state
    when the connection is {:connected, tokens} and the pipeline returns :unauthorized
      then a refresh is attempted with the stored refresh_token
        when the refresh succeeds
          then the new access_token and refresh_token replace the stored pair
          then the pipeline is replayed with the new access_token
          then the new watermark and pending_watches are written to plugin state
        if the refresh returns :invalid_grant
          then the connection flips to :unconnected
        if the refresh returns another error
          then plugin state is left unchanged
    when the connection is {:connected, tokens} and the pipeline returns another error
      then plugin state is left unchanged (watermark and pending_watches not touched)
```

### User_setup

```
Use-case: User_setup (src: lib/jido_watch/actions/user_setup.ex; unit: test/use_case/user_setup_test.exs)
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
Domain: Chunker (src: lib/jido_watch/chunker.ex; unit: test/domain/chunker_test.exs)
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
Domain: Srt (src: lib/jido_watch/srt.ex; unit: test/domain/srt_test.exs)
  parse/1
    then each block becomes a Cue with start_ms and end_ms parsed from the timestamp line
    then multi-line cue text is joined with newlines
    then blocks separated by extra blank lines parse the same as single-blank-separated
    when given an empty string
      then no cues are returned
    if a block has a malformed timestamp line
      then the error wraps the offending block index
```

## Port

Trees here describe outbound port contracts — what every implementation, in-memory
or real, must guarantee. The contract suite is a macro module that both the
in-memory adapter test and the real adapter test invoke; both reify the same
tree.

### Subtitle.Source

```
Port: Subtitle.Source (src: lib/jido_watch/subtitle/source.ex; unit: test/adapter/subtitle_in_memory_test.exs; integration: test/adapter/subtitle_open_subtitles_test.exs)
  fetch/2
    when given an entry whose subtitles are available
      then returns {:ok, list_of_cues}
    when given an entry whose subtitles cannot be found
      then returns {:ok, :no_transcript}
```

The watch-entry shape is intentionally not part of the port contract — each
adapter is free to expect whatever shape suits its lookup (the in-memory uses
`"id"`; the OpenSubtitles adapter uses `"type"`/`"movie"`/`"episode"` plus
nested imdb_id). The contract only fixes the output shape and error semantics.

### Trakt.Client

```
Port: Trakt.Client (src: lib/jido_watch/trakt/client.ex; unit: test/adapter/trakt_in_memory_test.exs; integration: test/adapter/trakt_http_test.exs)
  exchange_code/2
    when given a code the server accepts
      then returns {:ok, %{access_token, refresh_token, expires_in}}
    when given a code the server rejects
      then returns an error
  exchange_refresh_token/2
    when given a refresh token the server accepts
      then returns {:ok, %{access_token, refresh_token, expires_in}}
    when the refresh token is expired, revoked, or otherwise invalid
      then returns {:error, :invalid_grant}
  recent_watches/2
    when the access token is accepted
      then returns {:ok, list_of_entries}
    when the access token is rejected by the server
      then returns {:error, :unauthorized}
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
Adapter: Subtitle.OpenSubtitles (src: lib/jido_watch/subtitle/open_subtitles.ex; integration: test/adapter/subtitle_open_subtitles_test.exs)
  fetch/2
    when the watch entry is a movie with an imdb_id
      then it searches OpenSubtitles by imdb_id with the Api-Key and User-Agent headers
      then it returns the parsed cues from the SRT linked via /download
    when the watch entry is an episode with an imdb_id
      then it searches by the episode's imdb_id
    when the handle carries a bearer_token
      then /download is sent with Authorization: Bearer <token>
    if the search returns no subtitles
      then the result is {:ok, :no_transcript}
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
Adapter: Trakt.HTTP (src: lib/jido_watch/trakt/http.ex; integration: test/adapter/trakt_http_test.exs)
  exchange_code/2
    when given a valid auth code
      then it POSTs the code with client credentials and grant_type to /oauth/token
        and returns the parsed access_token, refresh_token and expires_in
    if Trakt responds with a non-200 status
      then the error wraps the status and body
  exchange_refresh_token/2
    when given a refresh token Trakt accepts
      then it POSTs the refresh_token with client credentials and grant_type=refresh_token to /oauth/token
        and returns the parsed access_token, refresh_token and expires_in
    if Trakt responds with 400 or 401
      then the error is :invalid_grant
    if Trakt responds with another non-200 status
      then the error wraps the status and body
  recent_watches/2
    when given a valid access token
      then it GETs /sync/history with bearer auth, trakt-api-version and trakt-api-key headers
        and returns the parsed list of entries
    if Trakt responds with 401
      then the error is :unauthorized
    if Trakt responds with another non-200 status
      then the error wraps the status and body
```
