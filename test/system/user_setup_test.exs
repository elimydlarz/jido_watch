defmodule JidoWatch.System.UserSetupTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Test.Support.TraktInMemory

  describe "when the agent calls the user_setup action for an unconnected user" do
    test "then an authorization URL is returned" do
      trakt = TraktInMemory.start!()

      {:ok, pid} =
        HostAgent.start_link(trakt: trakt, trakt_client_id: "client-abc")

      assert {:ok, url} = HostAgent.user_setup(pid)
      assert is_binary(url)
      assert url =~ "trakt.tv"
      assert url =~ "client_id=client-abc"
    end
  end

  describe "when called with a valid auth code for that user" do
    test "then the user becomes connected" do
      tokens = %{access_token: "tok-abc", refresh_token: "ref-abc", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"good-code" => tokens})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      refute HostAgent.connected?(pid)

      assert :ok = HostAgent.complete_user_setup(pid, "good-code")
      assert HostAgent.connected?(pid)
    end

    test "then a viewing profile of the user's pre-connection history is returned to the agent" do
      tokens = %{access_token: "tok-abc", refresh_token: "ref-abc", expires_in: 7_776_000}

      trakt =
        TraktInMemory.start!(
          codes: %{"good-code" => tokens},
          watched_shows: [
            %{"plays" => 12, "show" => %{"title" => "Severance", "genres" => ["drama", "scifi"]}},
            %{"plays" => 3, "show" => %{"title" => "The Bear", "genres" => ["drama", "comedy"]}}
          ],
          watched_movies: [
            %{"plays" => 1, "movie" => %{"title" => "Arrival", "genres" => ["scifi"]}}
          ],
          watches: [
            %{
              "type" => "episode",
              "watched_at" => "2026-05-20T00:00:00Z",
              "show" => %{"title" => "Severance"}
            }
          ],
          stats: %{
            "episodes" => %{"watched" => 540},
            "ratings" => %{"distribution" => %{"9" => 4, "10" => 2}}
          }
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      :ok = HostAgent.complete_user_setup(pid, "good-code")

      profile = HostAgent.viewing_profile(pid)
      assert profile.shows_watched == 2
      assert profile.movies_watched == 1
      assert profile.episodes_watched == 540
      assert profile.genre_distribution["drama"] == 2
      assert profile.genre_distribution["scifi"] == 2
      assert [%{title: "Severance", plays: 12} | _] = profile.most_watched_shows
      assert profile.ratings_distribution == %{"9" => 4, "10" => 2}
    end

    test "then subsequent polling only processes watches recorded after this moment" do
      tokens = %{access_token: "tok-abc", refresh_token: "ref-abc", expires_in: 7_776_000}

      old_entry = %{
        "id" => "old",
        "type" => "movie",
        "watched_at" => "2020-01-01T00:00:00Z",
        "movie" => %{"title" => "Old Movie", "ids" => %{"imdb" => "tt0"}}
      }

      trakt =
        TraktInMemory.start!(codes: %{"good-code" => tokens}, watches: [old_entry])

      subtitles =
        JidoWatch.Test.Support.SubtitleInMemory.start!(
          cues: %{"old" => [%JidoWatch.Subtitle.Cue{start_ms: 0, end_ms: 1_000, text: "x"}]}
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          subtitles: subtitles,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc",
          test_pid: self()
        )

      :ok = HostAgent.complete_user_setup(pid, "good-code")
      :ok = HostAgent.poll(pid)

      refute_receive {:watch_called, _}, 200
      refute_receive {:form_opinion_called, _}, 50
    end
  end

  describe "when called with an invalid code" do
    test "then the user does not become connected" do
      trakt = TraktInMemory.start!(codes: %{})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      assert {:error, _reason} = HostAgent.complete_user_setup(pid, "bad-code")
      refute HostAgent.connected?(pid)
    end
  end

  describe "when a user is not connected" do
    test "then no watching happens for them" do
      trakt = TraktInMemory.start!()

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      refute HostAgent.connected?(pid)

      :ok = HostAgent.poll(pid)

      assert TraktInMemory.recent_watches_calls(trakt) == 0
    end
  end
end
