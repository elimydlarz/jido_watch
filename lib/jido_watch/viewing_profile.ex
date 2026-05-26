defmodule JidoWatch.ViewingProfile do
  @moduledoc """
  A plugin-owned, factual snapshot of a user's Trakt backlog, built once at
  connection time from the watched lists, recent history, and stats.

  Facts only — counts, genre tallies, play counts, a ratings histogram. Reading
  the profile for taste is the agent's job, not the plugin's.
  """

  @enforce_keys [
    :shows_watched,
    :movies_watched,
    :episodes_watched,
    :genre_distribution,
    :most_watched_shows,
    :recently_watched,
    :ratings_distribution
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          shows_watched: non_neg_integer(),
          movies_watched: non_neg_integer(),
          episodes_watched: non_neg_integer(),
          genre_distribution: %{optional(String.t()) => pos_integer()},
          most_watched_shows: [%{title: String.t(), plays: non_neg_integer()}],
          recently_watched: [%{title: String.t() | nil, type: String.t(), watched_at: String.t()}],
          ratings_distribution: map()
        }

  @recently_watched_cap 20

  @spec build(%{watched_shows: [map()], watched_movies: [map()], recent: [map()], stats: map()}) ::
          t()
  def build(%{watched_shows: shows, watched_movies: movies, recent: recent, stats: stats}) do
    %__MODULE__{
      shows_watched: length(shows),
      movies_watched: length(movies),
      episodes_watched: get_in(stats, ["episodes", "watched"]) || 0,
      ratings_distribution: get_in(stats, ["ratings", "distribution"]) || %{},
      genre_distribution: genre_distribution(shows, movies),
      most_watched_shows: most_watched_shows(shows),
      recently_watched: recently_watched(recent)
    }
  end

  defp genre_distribution(shows, movies) do
    (Enum.map(shows, &media(&1, "show")) ++ Enum.map(movies, &media(&1, "movie")))
    |> Enum.flat_map(fn media -> Map.get(media, "genres", []) end)
    |> Enum.frequencies()
  end

  defp most_watched_shows(shows) do
    shows
    |> Enum.map(fn entry -> %{title: media(entry, "show")["title"], plays: entry["plays"]} end)
    |> Enum.sort_by(& &1.plays, :desc)
  end

  defp recently_watched(recent) do
    recent
    |> Enum.take(@recently_watched_cap)
    |> Enum.map(fn entry ->
      %{title: title_of(entry), type: entry["type"], watched_at: entry["watched_at"]}
    end)
  end

  defp media(entry, key), do: Map.get(entry, key, %{})

  defp title_of(%{"type" => "movie", "movie" => %{"title" => title}}), do: title
  defp title_of(%{"type" => "episode", "show" => %{"title" => title}}), do: title
  defp title_of(_), do: nil
end
