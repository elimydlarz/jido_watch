defmodule JidoWatch.Domain.ViewingProfileTest do
  use ExUnit.Case, async: true

  @moduletag :domain

  alias JidoWatch.ViewingProfile

  defp shows do
    [
      %{"plays" => 12, "show" => %{"title" => "Severance", "genres" => ["drama", "scifi"]}},
      %{"plays" => 3, "show" => %{"title" => "The Bear", "genres" => ["drama", "comedy"]}}
    ]
  end

  defp movies do
    [%{"plays" => 1, "movie" => %{"title" => "Arrival", "genres" => ["scifi"]}}]
  end

  defp recent do
    [
      %{"type" => "episode", "watched_at" => "2026-05-20T00:00:00Z", "show" => %{"title" => "Severance"}},
      %{"type" => "movie", "watched_at" => "2026-05-18T00:00:00Z", "movie" => %{"title" => "Arrival"}}
    ]
  end

  defp stats do
    %{"episodes" => %{"watched" => 540}, "ratings" => %{"distribution" => %{"9" => 4, "10" => 2}}}
  end

  describe "build/1 when given watched shows, watched movies, recent history, and stats" do
    test "then shows_watched is the number of watched shows" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.shows_watched == 2
    end

    test "then movies_watched is the number of watched movies" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.movies_watched == 1
    end

    test "then episodes_watched is taken from stats" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.episodes_watched == 540
    end

    test "then ratings_distribution is taken from stats" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.ratings_distribution == %{"9" => 4, "10" => 2}
    end

    test "then genre_distribution counts each genre across watched shows and movies" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.genre_distribution == %{"drama" => 2, "scifi" => 2, "comedy" => 1}
    end

    test "then most_watched_shows lists shows by play count, highest first" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})
      assert profile.most_watched_shows == [%{title: "Severance", plays: 12}, %{title: "The Bear", plays: 3}]
    end

    test "then recently_watched preserves the recent history order, newest first" do
      profile = ViewingProfile.build(%{watched_shows: shows(), watched_movies: movies(), recent: recent(), stats: stats()})

      assert profile.recently_watched == [
               %{title: "Severance", type: "episode", watched_at: "2026-05-20T00:00:00Z"},
               %{title: "Arrival", type: "movie", watched_at: "2026-05-18T00:00:00Z"}
             ]
    end
  end

  describe "build/1 when the recent history holds more entries than the recently_watched cap" do
    test "then only the most recent up to the cap are kept" do
      many =
        for i <- 1..50 do
          %{"type" => "movie", "watched_at" => "2026-05-#{rem(i, 28) + 1}T00:00:00Z", "movie" => %{"title" => "M#{i}"}}
        end

      profile = ViewingProfile.build(%{watched_shows: [], watched_movies: [], recent: many, stats: stats()})

      assert length(profile.recently_watched) == 20
      assert hd(profile.recently_watched).title == "M1"
    end
  end

  describe "build/1 when a watched title carries no genres" do
    test "then it adds to the watch counts but contributes nothing to genre_distribution" do
      no_genre_shows = [%{"plays" => 2, "show" => %{"title" => "Mystery"}}]

      profile = ViewingProfile.build(%{watched_shows: no_genre_shows, watched_movies: [], recent: [], stats: stats()})

      assert profile.shows_watched == 1
      assert profile.genre_distribution == %{}
    end
  end

  describe "build/1 when the watched lists and recent history are empty" do
    test "then a profile with zero counts and empty distributions is built" do
      profile = ViewingProfile.build(%{watched_shows: [], watched_movies: [], recent: [], stats: stats()})

      assert profile.shows_watched == 0
      assert profile.movies_watched == 0
      assert profile.genre_distribution == %{}
      assert profile.most_watched_shows == []
      assert profile.recently_watched == []
    end
  end
end
