defmodule JidoWatch.System.WatchingTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Test.Support.SubtitleInMemory
  alias JidoWatch.Test.Support.TraktInMemory

  describe "when the user watches new content" do
    test "then the agent's watch/2 is called once per chunk" do
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
            "ep-1" => [
              %Cue{start_ms: 0, end_ms: 1_000, text: "opening line"},
              %Cue{start_ms: 11 * 60_000, end_ms: 11 * 60_000 + 1_000, text: "later line"}
            ]
          }
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self()
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      assert_receive {:watch_called, _chunk_1}, 1_000
      assert_receive {:watch_called, _chunk_2}, 1_000
      refute_receive {:watch_called, _}, 200
    end

    test "then the agent's experience/3 is called once per angle, with the experiences from watch" do
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
            "ep-1" => [
              %Cue{start_ms: 0, end_ms: 1_000, text: "a"},
              %Cue{start_ms: 11 * 60_000, end_ms: 11 * 60_000 + 1_000, text: "b"}
            ]
          }
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self(),
          angles: [:emerging_themes, :loose_threads]
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      assert_receive {:experience_called, :emerging_themes, experiences_a}, 1_000
      assert_receive {:experience_called, :loose_threads, experiences_b}, 1_000
      refute_receive {:experience_called, _, _}, 200

      assert length(experiences_a) == 2
      assert length(experiences_b) == 2
      assert Enum.map(experiences_a, & &1.chunk.index) == [0, 1]
    end

    test "then the agent's form_opinion/2 is called once with the impressions from each angle" do
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
          angles: [:emerging_themes, :loose_threads]
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      assert_receive {:form_opinion_called, impressions}, 1_000
      refute_receive {:form_opinion_called, _}, 200

      assert Enum.map(impressions, & &1.angle) == [:emerging_themes, :loose_threads]
    end
  end

  describe "when the user has not watched anything new" do
    test "then no callbacks are called" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"code" => tokens}, watches: [])
      subtitles = SubtitleInMemory.start!(cues: %{})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self()
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      refute_receive {:watch_called, _}, 200
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50
    end
  end

  describe "when content the user watched cannot be processed" do
    test "then form_opinion/2 is not called" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}
      entry = %{"id" => "no-subs"}

      trakt = TraktInMemory.start!(codes: %{"code" => tokens}, watches: [entry])
      subtitles = SubtitleInMemory.start!(cues: %{})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self()
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      refute_receive {:form_opinion_called, _}, 300
    end
  end

  describe "when the same entry appears in a subsequent poll" do
    test "then the agent's callbacks are not invoked again for it" do
      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}

      future_watched_at =
        DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()

      entry = %{
        "id" => "ep-1",
        "type" => "movie",
        "watched_at" => future_watched_at,
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      trakt = TraktInMemory.start!(codes: %{"code" => tokens}, watches: [entry])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{"ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}]}
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client",
          trakt_client_secret: "secret",
          test_pid: self()
        )

      :ok = HostAgent.complete_user_setup(pid, "code")
      :ok = HostAgent.poll(pid)

      assert_receive {:watch_called, _}, 1_000
      assert_receive {:experience_called, _, _}, 1_000
      assert_receive {:form_opinion_called, _}, 1_000

      :ok = HostAgent.poll(pid)

      refute_receive {:watch_called, _}, 200
      refute_receive {:experience_called, _, _}, 50
      refute_receive {:form_opinion_called, _}, 50
    end
  end
end
