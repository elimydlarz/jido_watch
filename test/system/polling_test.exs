defmodule JidoWatch.System.PollingTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Test.Support.SubtitleInMemory
  alias JidoWatch.Test.Support.TraktInMemory

  describe "when the plugin is mounted with no user connected" do
    test "then no polls fire" do
      trakt = TraktInMemory.start!(codes: %{}, watches: [])
      subtitles = SubtitleInMemory.start!(cues: %{})

      {:ok, _pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: 0.02
        )

      refute_receive {:watch_called, _}, 2_500
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50
    end
  end

  describe "when the plugin is mounted with no user connected and the user becomes connected via user_setup" do
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

    test "then they continue for as long as the agent runs" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}

      trakt = TraktInMemory.start!(codes: %{"code" => tokens}, watches: [])
      subtitles = SubtitleInMemory.start!(cues: %{})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: 0.02
        )

      :ok = HostAgent.complete_user_setup(pid, "code")

      poll_count_before = TraktInMemory.recent_watches_calls(trakt)
      Process.sleep(4_500)
      poll_count_after = TraktInMemory.recent_watches_calls(trakt)

      assert poll_count_after - poll_count_before >= 3
    end
  end

  describe "when the plugin is mounted with the user already connected" do
    test "then polls begin firing on the configured interval" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      entry = %{"id" => "ep-1"}

      trakt = TraktInMemory.start!(codes: %{}, watches: [entry])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{
            "ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "a"}]
          }
        )

      {:ok, _pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: 0.02,
          connection: {:connected, tokens}
        )

      refute_receive {:watch_called, _}, 800
      assert_receive {:watch_called, _}, 2_000
    end
  end

  describe "when the plugin mounts with a custom :poll_interval_minutes in plugin state" do
    test "then polls fire on that interval rather than the default" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{}, watches: [])
      subtitles = SubtitleInMemory.start!(cues: %{})

      interval_minutes = 0.02
      interval_ms = round(interval_minutes * 60_000)

      {:ok, _pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: interval_minutes,
          connection: {:connected, tokens}
        )

      Process.sleep(3 * interval_ms + 300)
      calls = TraktInMemory.recent_watches_calls(trakt)

      assert calls in 3..5,
             "expected ~3 polls at #{interval_ms}ms interval over #{3 * interval_ms + 300}ms, got #{calls}"
    end
  end

  describe "if Trakt errors during a poll" do
    test "then the agent does not crash, no callbacks fire, the watermark is not advanced, and polling continues on the next interval" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      watermark = ~U[2025-06-01 12:00:00Z]

      trakt =
        TraktInMemory.start!(
          codes: %{},
          watches: [],
          recent_watches_error: {:trakt_unavailable, 503}
        )

      subtitles = SubtitleInMemory.start!(cues: %{})

      interval_minutes = 0.02
      interval_ms = round(interval_minutes * 60_000)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: interval_minutes,
          connection: {:connected, tokens},
          watermark: watermark
        )

      Process.sleep(3 * interval_ms + 300)

      assert Process.alive?(pid)
      refute_receive {:watch_called, _}, 50
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50
      assert HostAgent.watermark(pid) == watermark
      assert TraktInMemory.recent_watches_calls(trakt) >= 3
    end
  end

  describe "when the agent terminates" do
    test "then polling stops" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{}, watches: [])
      subtitles = SubtitleInMemory.start!(cues: %{})

      interval_minutes = 0.02
      interval_ms = round(interval_minutes * 60_000)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: interval_minutes,
          connection: {:connected, tokens}
        )

      Process.sleep(2 * interval_ms)
      calls_while_alive = TraktInMemory.recent_watches_calls(trakt)
      assert calls_while_alive >= 1

      GenServer.stop(pid, :normal)
      refute Process.alive?(pid)

      Process.sleep(3 * interval_ms)
      calls_after_termination = TraktInMemory.recent_watches_calls(trakt)

      assert calls_after_termination == calls_while_alive
    end
  end
end
