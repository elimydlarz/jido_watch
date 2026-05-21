defmodule JidoWatch.UseCase.WatchingTest do
  use ExUnit.Case, async: true

  @moduletag :use_case

  alias Jido.Agent
  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Test.Support.RecordingHost
  alias JidoWatch.Test.Support.SubtitleInMemory
  alias JidoWatch.Test.Support.TraktInMemory
  alias JidoWatch.Watching

  describe "run/1 when there are new watch entries with fetchable subtitles" do
    test "then watch/2 is called once per chunk in window order" do
      entry = %{"id" => "ep-1"}

      trakt = TraktInMemory.start!(watches: [entry])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{
            "ep-1" => [
              %Cue{start_ms: 0, end_ms: 1_000, text: "first window"},
              %Cue{start_ms: 11 * 60_000, end_ms: 11 * 60_000 + 1_000, text: "second window"},
              %Cue{start_ms: 21 * 60_000, end_ms: 21 * 60_000 + 1_000, text: "third window"}
            ]
          }
        )

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      {:ok, _} =
        Watching.run(%{
          trakt: trakt,
          subtitles: subtitles,
          access_token: "tok",
          host: RecordingHost,
          agent: agent,
          angles: [:theme]
        })

      assert_receive {:watch_called, %{index: 0}}
      assert_receive {:watch_called, %{index: 1}}
      assert_receive {:watch_called, %{index: 2}}
      refute_receive {:watch_called, _}, 50
    end
  end

  describe "run/1 when an entry's watched_at is no later than the watermark" do
    test "then it is skipped" do
      watermark = ~U[2025-06-01 12:00:00Z]

      old_entry = %{
        "id" => "old",
        "type" => "movie",
        "watched_at" => "2025-06-01T11:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      same_moment_entry = %{
        "id" => "same",
        "type" => "movie",
        "watched_at" => "2025-06-01T12:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt1"}}
      }

      trakt = TraktInMemory.start!(watches: [old_entry, same_moment_entry])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{
            "old" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}],
            "same" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}]
          }
        )

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      Watching.run(%{
        trakt: trakt,
        subtitles: subtitles,
        access_token: "tok",
        host: RecordingHost,
        agent: agent,
        angles: [:theme],
        watermark: watermark
      })

      refute_receive {:watch_called, _}, 50
    end
  end

  describe "run/1 when an entry has no transcript available" do
    test "then no callbacks fire for it, the watermark still advances past it, and it stays on pending_watches for the next tick" do
      entry = %{
        "id" => "no-subs",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt9999"}}
      }

      trakt = TraktInMemory.start!(watches: [entry])
      subtitles = SubtitleInMemory.start!(cues: %{})

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      assert {:ok, %{watermark: new_watermark, pending_watches: pending}} =
               Watching.run(%{
                 trakt: trakt,
                 subtitles: subtitles,
                 access_token: "tok",
                 host: RecordingHost,
                 agent: agent,
                 angles: [:theme]
               })

      refute_receive {:watch_called, _}, 50
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50

      assert new_watermark == ~U[2025-07-01 00:00:00Z]
      assert pending == [entry]
    end
  end

  describe "run/1 when an entry is already on pending_watches and its transcript is now available" do
    test "then it is processed and removed from pending_watches" do
      entry = %{
        "id" => "ep-late",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      trakt = TraktInMemory.start!(watches: [])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{"ep-late" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}]}
        )

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      assert {:ok, %{pending_watches: []}} =
               Watching.run(%{
                 trakt: trakt,
                 subtitles: subtitles,
                 access_token: "tok",
                 host: RecordingHost,
                 agent: agent,
                 angles: [:theme],
                 watermark: ~U[2025-07-01 00:00:00Z],
                 pending_watches: [entry]
               })

      assert_receive {:watch_called, _}
      assert_receive {:form_opinion_called, _}
    end
  end

  describe "run/1 when a Trakt entry is already on pending_watches" do
    test "then it is not added again" do
      entry = %{
        "id" => "ep-dup",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      trakt = TraktInMemory.start!(watches: [entry])
      subtitles = SubtitleInMemory.start!(cues: %{})

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      assert {:ok, %{pending_watches: pending}} =
               Watching.run(%{
                 trakt: trakt,
                 subtitles: subtitles,
                 access_token: "tok",
                 host: RecordingHost,
                 agent: agent,
                 angles: [:theme],
                 pending_watches: [entry]
               })

      assert pending == [entry]
    end
  end

  describe "run/1" do
    test "then the returned watermark is the maximum of the input watermark and every attempted entry's watched_at" do
      watermark = ~U[2025-06-01 12:00:00Z]

      old_entry = %{
        "id" => "old",
        "type" => "movie",
        "watched_at" => "2025-05-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      newer_entry = %{
        "id" => "newer",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt1"}}
      }

      newest_entry = %{
        "id" => "newest",
        "type" => "movie",
        "watched_at" => "2025-08-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt2"}}
      }

      trakt = TraktInMemory.start!(watches: [old_entry, newer_entry, newest_entry])

      cue = %Cue{start_ms: 0, end_ms: 1_000, text: "x"}

      subtitles =
        SubtitleInMemory.start!(
          cues: %{"old" => [cue], "newer" => [cue], "newest" => [cue]}
        )

      agent = %Agent{id: "test-agent", state: %{test_pid: self()}}

      assert {:ok, new_watermark} =
               Watching.run(%{
                 trakt: trakt,
                 subtitles: subtitles,
                 access_token: "tok",
                 host: RecordingHost,
                 agent: agent,
                 angles: [:theme],
                 watermark: watermark
               })

      assert new_watermark == ~U[2025-08-01 00:00:00Z]
    end
  end
end
