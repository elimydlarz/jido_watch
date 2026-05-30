defmodule JidoWatch.Adapter.TraktHTTPTest do
  use ExUnit.Case, async: true

  @moduletag :adapter

  alias JidoWatch.Trakt.HTTP

  require JidoWatch.Test.Support.TraktClientContract
  alias JidoWatch.Test.Support.TraktClientContract

  defp setup_for(scenario) do
    {HTTP, HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug_for(scenario))}
  end

  defp plug_for(:exchange_code_valid) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "tok-x",
          "refresh_token" => "ref-x",
          "expires_in" => 7_776_000
        })
      )
    end
  end

  defp plug_for(:exchange_code_invalid) do
    fn conn -> Plug.Conn.send_resp(conn, 401, "") end
  end

  defp plug_for(:refresh_valid) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "tok-y",
          "refresh_token" => "ref-y",
          "expires_in" => 86_400
        })
      )
    end
  end

  defp plug_for(:refresh_invalid_grant) do
    fn conn -> Plug.Conn.send_resp(conn, 401, "") end
  end

  defp plug_for(:recent_watches_valid) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!([%{"id" => 1}]))
    end
  end

  defp plug_for(:recent_watches_unauthorized) do
    fn conn -> Plug.Conn.send_resp(conn, 401, "") end
  end

  defp plug_for(scenario) when scenario in [:watched_shows_valid, :watched_movies_valid] do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!([%{"plays" => 1}]))
    end
  end

  defp plug_for(:stats_valid) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"episodes" => %{"watched" => 1}}))
    end
  end

  defp plug_for(scenario)
       when scenario in [
              :watched_shows_unauthorized,
              :watched_movies_unauthorized,
              :stats_unauthorized
            ] do
    fn conn -> Plug.Conn.send_resp(conn, 401, "") end
  end

  TraktClientContract.run()

  describe "exchange_code/2 when given a valid auth code" do
    test "then it POSTs the code with client credentials and grant_type to /oauth/token and returns the parsed access_token, refresh_token and expires_in" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/oauth/token"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{
                 "code" => "good-code",
                 "client_id" => "id-abc",
                 "client_secret" => "secret-xyz",
                 "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
                 "grant_type" => "authorization_code"
               }

        response = %{
          "access_token" => "tok-1",
          "refresh_token" => "ref-1",
          "expires_in" => 7_776_000
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:ok, tokens} = HTTP.exchange_code(handle, "good-code")
      assert tokens.access_token == "tok-1"
      assert tokens.refresh_token == "ref-1"
      assert tokens.expires_in == 7_776_000
    end
  end

  describe "exchange_code/2 if Trakt responds with a non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "invalid_client"}))
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:error, {:trakt_status, 401, %{"error" => "invalid_client"}}} =
               HTTP.exchange_code(handle, "bad-code")
    end
  end

  describe "exchange_refresh_token/2 when given a refresh token Trakt accepts" do
    test "then it POSTs the refresh_token with client credentials and grant_type=refresh_token to /oauth/token and returns the parsed access_token, refresh_token and expires_in" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/oauth/token"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{
                 "refresh_token" => "ref-1",
                 "client_id" => "id-abc",
                 "client_secret" => "secret-xyz",
                 "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
                 "grant_type" => "refresh_token"
               }

        response = %{
          "access_token" => "tok-2",
          "refresh_token" => "ref-2",
          "expires_in" => 86_400
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:ok, tokens} = HTTP.exchange_refresh_token(handle, "ref-1")
      assert tokens.access_token == "tok-2"
      assert tokens.refresh_token == "ref-2"
      assert tokens.expires_in == 86_400
    end
  end

  describe "exchange_refresh_token/2 if Trakt responds with 400 or 401" do
    test "then the error is :invalid_grant" do
      for status <- [400, 401] do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => "invalid_grant"}))
        end

        handle =
          HTTP.new(
            client_id: "id-abc",
            client_secret: "secret-xyz",
            plug: plug
          )

        assert {:error, :invalid_grant} = HTTP.exchange_refresh_token(handle, "ref-dead")
      end
    end
  end

  describe "exchange_refresh_token/2 if Trakt responds with another non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, "")
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:error, {:trakt_status, 503, ""}} = HTTP.exchange_refresh_token(handle, "ref-1")
    end
  end

  describe "recent_watches/2 when given a valid access token" do
    test "then it GETs /sync/history with bearer auth, trakt-api-version and trakt-api-key headers and returns the parsed list of entries" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/sync/history"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-version") == ["2"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-key") == ["id-abc"]

        entries = [%{"id" => 1}, %{"id" => 2}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(entries))
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:ok, [%{"id" => 1}, %{"id" => 2}]} = HTTP.recent_watches(handle, "tok-1")
    end
  end

  describe "recent_watches/2 if Trakt responds with 401" do
    test "then the error is :unauthorized" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, "")
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:error, :unauthorized} = HTTP.recent_watches(handle, "tok-1")
    end
  end

  describe "recent_watches/2 if Trakt responds 200 with a body that is not a list" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"error" => "unexpected"}))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 200, %{"error" => "unexpected"}}} = HTTP.recent_watches(handle, "tok-1")
    end
  end

  describe "recent_watches/2 if Trakt responds with another non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, "")
      end

      handle =
        HTTP.new(
          client_id: "id-abc",
          client_secret: "secret-xyz",
          plug: plug
        )

      assert {:error, {:trakt_status, 403, ""}} = HTTP.recent_watches(handle, "tok-1")
    end
  end

  describe "watched_shows/2 when given a valid access token" do
    test "then it GETs /sync/watched/shows with extended=full, bearer auth, trakt-api-version and trakt-api-key headers and returns the parsed list of shows with play counts and genres" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/sync/watched/shows"
        assert conn.query_string == "extended=full"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-version") == ["2"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-key") == ["id-abc"]

        shows = [%{"plays" => 12, "show" => %{"title" => "Severance", "genres" => ["drama"]}}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(shows))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)

      assert {:ok, [%{"plays" => 12, "show" => %{"title" => "Severance", "genres" => ["drama"]}}]} =
               HTTP.watched_shows(handle, "tok-1")
    end
  end

  describe "watched_shows/2 if Trakt responds with 401" do
    test "then the error is :unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, :unauthorized} = HTTP.watched_shows(handle, "tok-1")
    end
  end

  describe "watched_shows/2 if Trakt responds 200 with a body that is not a list" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"error" => "unexpected"}))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 200, %{"error" => "unexpected"}}} = HTTP.watched_shows(handle, "tok-1")
    end
  end

  describe "watched_shows/2 if Trakt responds with another non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 403, ""}} = HTTP.watched_shows(handle, "tok-1")
    end
  end

  describe "watched_movies/2 when given a valid access token" do
    test "then it GETs /sync/watched/movies with extended=full, bearer auth, trakt-api-version and trakt-api-key headers and returns the parsed list of movies with play counts and genres" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/sync/watched/movies"
        assert conn.query_string == "extended=full"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-version") == ["2"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-key") == ["id-abc"]

        movies = [%{"plays" => 1, "movie" => %{"title" => "Arrival", "genres" => ["scifi"]}}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(movies))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)

      assert {:ok, [%{"plays" => 1, "movie" => %{"title" => "Arrival", "genres" => ["scifi"]}}]} =
               HTTP.watched_movies(handle, "tok-1")
    end
  end

  describe "watched_movies/2 if Trakt responds with 401" do
    test "then the error is :unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, :unauthorized} = HTTP.watched_movies(handle, "tok-1")
    end
  end

  describe "watched_movies/2 if Trakt responds 200 with a body that is not a list" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"error" => "unexpected"}))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 200, %{"error" => "unexpected"}}} = HTTP.watched_movies(handle, "tok-1")
    end
  end

  describe "watched_movies/2 if Trakt responds with another non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 403, ""}} = HTTP.watched_movies(handle, "tok-1")
    end
  end

  describe "stats/2 when given a valid access token" do
    test "then it GETs /users/me/stats with bearer auth, trakt-api-version and trakt-api-key headers and returns the parsed stats" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/users/me/stats"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-version") == ["2"]
        assert Plug.Conn.get_req_header(conn, "trakt-api-key") == ["id-abc"]

        stats = %{
          "episodes" => %{"watched" => 540},
          "ratings" => %{"distribution" => %{"10" => 2}}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stats))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)

      assert {:ok,
              %{"episodes" => %{"watched" => 540}, "ratings" => %{"distribution" => %{"10" => 2}}}} =
               HTTP.stats(handle, "tok-1")
    end
  end

  describe "stats/2 if Trakt responds with 401" do
    test "then the error is :unauthorized" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, :unauthorized} = HTTP.stats(handle, "tok-1")
    end
  end

  describe "stats/2 if Trakt responds 200 with a body that is not a map" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([%{"error" => "unexpected"}]))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 200, [%{"error" => "unexpected"}]}} = HTTP.stats(handle, "tok-1")
    end
  end

  describe "stats/2 if Trakt responds with another non-200 status" do
    test "then the error wraps the status and body" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "") end
      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      assert {:error, {:trakt_status, 403, ""}} = HTTP.stats(handle, "tok-1")
    end
  end

  # ── Trakt response-shape contract tests ─────────────────────────────────
  #
  # Each test below stubs the adapter with a realistic Trakt response payload
  # (captured from https://trakt.docs.apiary.io) and asserts the keys the
  # rest of the codebase actually reads. These fixtures are the contract
  # documentation for "what does Trakt return" — a contributor can read the
  # maps below to learn the wire format.

  describe "recent_watches/2 when Trakt returns a representative /sync/history payload" do
    test "then each entry preserves type, watched_at, and the matching movie or episode+show object with title and imdb id" do
      movie_entry = %{
        "id" => 3_482_351_236,
        "watched_at" => "2026-05-20T18:12:09.000Z",
        "action" => "scrobble",
        "type" => "movie",
        "movie" => %{
          "title" => "Arrival",
          "year" => 2016,
          "ids" => %{
            "trakt" => 264_424,
            "slug" => "arrival-2016",
            "imdb" => "tt2543164",
            "tmdb" => 329_865
          }
        }
      }

      episode_entry = %{
        "id" => 3_482_359_802,
        "watched_at" => "2026-05-21T20:30:01.000Z",
        "action" => "scrobble",
        "type" => "episode",
        "episode" => %{
          "season" => 1,
          "number" => 9,
          "title" => "The We We Are",
          "ids" => %{
            "trakt" => 4_055_309,
            "tvdb" => 8_550_354,
            "imdb" => "tt14288696",
            "tmdb" => 2_198_158
          }
        },
        "show" => %{
          "title" => "Severance",
          "year" => 2022,
          "ids" => %{
            "trakt" => 156_869,
            "slug" => "severance",
            "tvdb" => 371_980,
            "imdb" => "tt11280740",
            "tmdb" => 95_396,
            "tvrage" => nil
          }
        }
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([movie_entry, episode_entry]))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      {:ok, [movie, episode]} = HTTP.recent_watches(handle, "tok-1")

      assert movie["type"] == "movie"
      assert movie["watched_at"] == "2026-05-20T18:12:09.000Z"
      assert movie["movie"]["title"] == "Arrival"
      assert movie["movie"]["ids"]["imdb"] == "tt2543164"

      assert episode["type"] == "episode"
      assert episode["watched_at"] == "2026-05-21T20:30:01.000Z"
      assert episode["episode"]["title"] == "The We We Are"
      assert episode["episode"]["ids"]["imdb"] == "tt14288696"
      assert episode["show"]["title"] == "Severance"
    end
  end

  describe "watched_shows/2 when Trakt returns a representative /sync/watched/shows payload with extended=full" do
    test "then each entry preserves plays and the show object's title and genres" do
      entry = %{
        "plays" => 19,
        "last_watched_at" => "2026-05-21T20:30:01.000Z",
        "last_updated_at" => "2026-05-21T20:30:01.000Z",
        "reset_at" => nil,
        "show" => %{
          "title" => "Severance",
          "year" => 2022,
          "ids" => %{
            "trakt" => 156_869,
            "slug" => "severance",
            "tvdb" => 371_980,
            "imdb" => "tt11280740",
            "tmdb" => 95_396,
            "tvrage" => nil
          },
          "overview" => "Mark leads a team of office workers whose memories have been surgically divided.",
          "first_aired" => "2022-02-18T08:00:00.000Z",
          "runtime" => 60,
          "certification" => "TV-MA",
          "network" => "Apple TV+",
          "country" => "us",
          "status" => "returning series",
          "rating" => 8.49,
          "votes" => 25_000,
          "language" => "en",
          "languages" => ["en"],
          "available_translations" => ["en", "es"],
          "genres" => ["drama", "mystery", "science-fiction", "thriller"],
          "aired_episodes" => 19
        },
        "seasons" => [
          %{
            "number" => 1,
            "episodes" => [
              %{"number" => 1, "plays" => 1, "last_watched_at" => "2022-02-18T20:00:00.000Z"}
            ]
          }
        ]
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([entry]))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      {:ok, [parsed]} = HTTP.watched_shows(handle, "tok-1")

      assert parsed["plays"] == 19
      assert parsed["show"]["title"] == "Severance"
      assert parsed["show"]["genres"] == ["drama", "mystery", "science-fiction", "thriller"]
    end
  end

  describe "watched_movies/2 when Trakt returns a representative /sync/watched/movies payload with extended=full" do
    test "then each entry preserves plays and the movie object's title and genres" do
      entry = %{
        "plays" => 1,
        "last_watched_at" => "2026-05-20T18:12:09.000Z",
        "last_updated_at" => "2026-05-20T18:12:09.000Z",
        "movie" => %{
          "title" => "Arrival",
          "year" => 2016,
          "ids" => %{
            "trakt" => 264_424,
            "slug" => "arrival-2016",
            "imdb" => "tt2543164",
            "tmdb" => 329_865
          },
          "tagline" => "Why are they here?",
          "overview" => "Taking place after alien crafts land around the world, an expert linguist is recruited.",
          "released" => "2016-11-11",
          "runtime" => 116,
          "country" => "us",
          "status" => "released",
          "rating" => 7.92,
          "votes" => 15_000,
          "language" => "en",
          "languages" => ["en"],
          "available_translations" => ["en", "es"],
          "genres" => ["science-fiction", "drama", "mystery"],
          "certification" => "PG-13"
        }
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([entry]))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      {:ok, [parsed]} = HTTP.watched_movies(handle, "tok-1")

      assert parsed["plays"] == 1
      assert parsed["movie"]["title"] == "Arrival"
      assert parsed["movie"]["genres"] == ["science-fiction", "drama", "mystery"]
    end
  end

  describe "stats/2 when Trakt returns a representative /users/me/stats payload" do
    test "then it preserves episodes.watched and ratings.distribution" do
      stats = %{
        "movies" => %{
          "plays" => 155,
          "watched" => 114,
          "minutes" => 16_273,
          "collected" => 110,
          "ratings" => 110,
          "comments" => 5
        },
        "shows" => %{"watched" => 24, "collected" => 24, "ratings" => 0, "comments" => 0},
        "seasons" => %{"ratings" => 0, "comments" => 0},
        "episodes" => %{
          "plays" => 552,
          "watched" => 534,
          "minutes" => 17_330,
          "collected" => 175,
          "ratings" => 64,
          "comments" => 4
        },
        "network" => %{"friends" => 1, "followers" => 4, "following" => 4},
        "ratings" => %{
          "total" => 174,
          "distribution" => %{
            "1" => 1,
            "2" => 0,
            "3" => 0,
            "4" => 1,
            "5" => 7,
            "6" => 15,
            "7" => 39,
            "8" => 65,
            "9" => 26,
            "10" => 20
          }
        }
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stats))
      end

      handle = HTTP.new(client_id: "id-abc", client_secret: "secret-xyz", plug: plug)
      {:ok, parsed} = HTTP.stats(handle, "tok-1")

      assert parsed["episodes"]["watched"] == 534

      assert parsed["ratings"]["distribution"] == %{
               "1" => 1,
               "2" => 0,
               "3" => 0,
               "4" => 1,
               "5" => 7,
               "6" => 15,
               "7" => 39,
               "8" => 65,
               "9" => 26,
               "10" => 20
             }
    end
  end
end
