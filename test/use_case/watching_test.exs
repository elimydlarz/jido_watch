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

      :ok =
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
end
