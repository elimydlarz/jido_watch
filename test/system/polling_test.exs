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

  describe "when Trakt returns 401 for a request during a poll and the refresh succeeds" do
    test "then the new tokens replace the stored pair, the original request is retried with the new access token, and the tick proceeds normally from there" do
      old_tokens = %{access_token: "old-tok", refresh_token: "ref-1", expires_in: 7_776_000}
      new_tokens = %{access_token: "new-tok", refresh_token: "ref-2", expires_in: 7_776_000}
      entry = %{"id" => "ep-1"}

      trakt =
        TraktInMemory.start!(
          codes: %{},
          watches: [entry],
          unauthorized_access_tokens: ["old-tok"],
          refresh_chain: %{"ref-1" => new_tokens}
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
          poll_interval_minutes: 0.02,
          connection: {:connected, old_tokens}
        )

      assert_receive {:watch_called, _}, 3_000

      {:ok, %{access_token: stored_access, refresh_token: stored_refresh}} =
        HostAgent.tokens(pid)

      assert stored_access == "new-tok"
      assert stored_refresh == "ref-2"
    end
  end

  describe "when Trakt returns 401 for a request during a poll and the refresh returns an invalid-grant response" do
    test "then the user becomes unconnected, no further polls fire, and re-running user_setup with a valid code resumes polling" do
      old_tokens = %{access_token: "old-tok", refresh_token: "ref-dead", expires_in: 7_776_000}
      fresh_tokens = %{access_token: "fresh-tok", refresh_token: "fresh-ref", expires_in: 7_776_000}
      entry = %{"id" => "ep-1"}

      trakt =
        TraktInMemory.start!(
          codes: %{"good-code" => fresh_tokens},
          watches: [entry],
          unauthorized_access_tokens: ["old-tok"],
          refresh_chain: %{}
        )

      subtitles =
        SubtitleInMemory.start!(
          cues: %{
            "ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "a"}]
          }
        )

      interval_minutes = 0.02
      interval_ms = round(interval_minutes * 60_000)

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          poll_interval_minutes: interval_minutes,
          connection: {:connected, old_tokens}
        )

      Process.sleep(2 * interval_ms + 300)

      refute HostAgent.connected?(pid)
      refute_receive {:watch_called, _}, 50

      calls_before = TraktInMemory.recent_watches_calls(trakt)
      Process.sleep(3 * interval_ms)
      calls_after = TraktInMemory.recent_watches_calls(trakt)
      assert calls_after == calls_before

      :ok = HostAgent.complete_user_setup(pid, "good-code")

      assert_receive {:watch_called, _}, 3_000
    end
  end

  describe "when Trakt fails transiently for a request during a poll and an attempt succeeds within three" do
    test "then the tick proceeds normally from there" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      entry = %{"id" => "ep-1"}

      trakt =
        TraktInMemory.start!(
          codes: %{},
          watches: [entry],
          transient_failures_remaining: 2,
          transient_error: {:trakt_status, 503, ""}
        )

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
          transient_retry_delay_ms: 10,
          connection: {:connected, tokens}
        )

      assert_receive {:watch_called, _}, 3_000
    end
  end

  describe "when Trakt fails transiently for a request during a poll and all three attempts fail" do
    test "then the agent does not crash, no callbacks fire, the watermark is not advanced, and polling continues on the next interval" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      watermark = ~U[2025-06-01 12:00:00Z]

      trakt =
        TraktInMemory.start!(
          codes: %{},
          watches: [],
          transient_failures_remaining: 100,
          transient_error: {:trakt_status, 503, ""}
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
          transient_retry_delay_ms: 10,
          connection: {:connected, tokens},
          watermark: watermark
        )

      Process.sleep(2 * interval_ms + 300)

      assert Process.alive?(pid)
      refute_receive {:watch_called, _}, 50
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50
      assert HostAgent.watermark(pid) == watermark
      assert TraktInMemory.recent_watches_calls(trakt) >= 6
    end
  end

  describe "when the refresh call itself fails transiently and an attempt succeeds within three" do
    test "then the tick proceeds normally from there" do
      old_tokens = %{access_token: "old-tok", refresh_token: "ref-1", expires_in: 7_776_000}
      new_tokens = %{access_token: "new-tok", refresh_token: "ref-2", expires_in: 7_776_000}
      entry = %{"id" => "ep-1"}

      trakt =
        TraktInMemory.start!(
          codes: %{},
          watches: [entry],
          unauthorized_access_tokens: ["old-tok"],
          refresh_chain: %{"ref-1" => new_tokens},
          refresh_transient_failures_remaining: 2,
          transient_error: {:trakt_status, 503, ""}
        )

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
          transient_retry_delay_ms: 10,
          connection: {:connected, old_tokens}
        )

      assert_receive {:watch_called, _}, 3_000
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
