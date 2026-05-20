defmodule JidoWatch.System.PollingTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Test.Support.SubtitleInMemory
  alias JidoWatch.Test.Support.TraktInMemory

  describe "when the plugin is mounted with no user connected" do
    describe "when the user becomes connected via user_setup" do
      test "then polls begin firing on the configured interval" do
        tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
        entry = %{"id" => "ep-1"}

        trakt =
          TraktInMemory.start!(
            codes: %{"code" => tokens},
            watches: [entry]
          )

        subtitles =
          SubtitleInMemory.start!(
            cues: %{
              "ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "a"}]
            }
          )

        {:ok, pid} =
          HostAgent.start_link(
            trakt: trakt,
            subtitles: subtitles,
            trakt_client_id: "client",
            trakt_client_secret: "secret",
            test_pid: self(),
            poll_interval_minutes: 0.05
          )

        :ok = HostAgent.complete_user_setup(pid, "code")

        refute_receive {:watch_called, _}, 1_500
        assert_receive {:watch_called, _}, 3_000
      end
    end
  end
end
