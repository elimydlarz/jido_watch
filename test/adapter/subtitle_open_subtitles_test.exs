defmodule JidoWatch.Adapter.SubtitleOpenSubtitlesTest do
  use ExUnit.Case, async: true

  @moduletag :adapter

  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Subtitle.OpenSubtitles

  require JidoWatch.Test.Support.SubtitleSourceContract
  alias JidoWatch.Test.Support.SubtitleSourceContract

  defp handle(plug) do
    OpenSubtitles.new(
      api_key: "key-abc",
      user_agent: "jido_watch test",
      plug: plug
    )
  end

  defp srt_body do
    """
    1
    00:00:01,000 --> 00:00:04,000
    Hello
    """
  end

  defp setup_for(:fetch_available) do
    entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}
    {OpenSubtitles, handle(happy_plug(srt_body())), entry}
  end

  defp setup_for(:fetch_unavailable) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))
    end

    entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt0000000"}}}
    {OpenSubtitles, handle(plug), entry}
  end

  SubtitleSourceContract.run()

  defp happy_plug(srt) do
    fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/subtitles"} ->
          conn = Plug.Conn.fetch_query_params(conn)

          response = %{
            "data" => [
              %{
                "attributes" => %{
                  "files" => [%{"file_id" => 9001}],
                  "imdb_id" => conn.query_params["imdb_id"]
                }
              }
            ]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))

        {"POST", "/api/v1/download"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"link" => "https://cdn.test/file.srt"}))

        {"GET", "/file.srt"} ->
          Plug.Conn.send_resp(conn, 200, srt)
      end
    end
  end

  describe "fetch/2 when the watch entry is a movie with an imdb_id" do
    test "then it searches OpenSubtitles by imdb_id with the Api-Key and User-Agent headers" do
      test_pid = self()

      plug = fn conn ->
        if conn.method == "GET" and conn.request_path == "/api/v1/subtitles" do
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:search, conn.query_params, Enum.into(conn.req_headers, %{})})
        end

        happy_plug(srt_body()).(conn)
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:ok, _} = OpenSubtitles.fetch(handle(plug), entry)

      assert_received {:search, query, headers}
      assert query["imdb_id"] == "tt1234567"
      assert query["languages"] == "en"
      assert headers["api-key"] == "key-abc"
      assert headers["user-agent"] == "jido_watch test"
    end

    test "then it returns the parsed cues from the SRT linked via /download" do
      test_pid = self()

      plug = fn conn ->
        if conn.method == "POST" and conn.request_path == "/api/v1/download" do
          {:ok, raw, _} = Plug.Conn.read_body(conn)
          send(test_pid, {:download, Jason.decode!(raw)})
        end

        happy_plug(srt_body()).(conn)
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:ok, [%Cue{start_ms: 1_000, end_ms: 4_000, text: "Hello"}]} =
               OpenSubtitles.fetch(handle(plug), entry)

      assert_received {:download, %{"file_id" => 9001}}
    end
  end

  describe "fetch/2 when the watch entry is an episode with an imdb_id" do
    test "then it searches by the episode's imdb_id" do
      test_pid = self()

      plug = fn conn ->
        if conn.method == "GET" and conn.request_path == "/api/v1/subtitles" do
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:search_imdb, conn.query_params["imdb_id"]})
        end

        happy_plug(srt_body()).(conn)
      end

      entry = %{
        "type" => "episode",
        "episode" => %{"ids" => %{"imdb" => "tt9876543"}},
        "show" => %{"ids" => %{"imdb" => "tt0000001"}}
      }

      assert {:ok, _} = OpenSubtitles.fetch(handle(plug), entry)
      assert_received {:search_imdb, "tt9876543"}
    end
  end

  describe "fetch/2 if the search returns no subtitles" do
    test "then the error is :no_subtitles" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:error, :no_subtitles} = OpenSubtitles.fetch(handle(plug), entry)
    end
  end

  describe "fetch/2 if /subtitles responds non-200" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "bad key"}))
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:error, {:opensubtitles_status, 401, %{"message" => "bad key"}}} =
               OpenSubtitles.fetch(handle(plug), entry)
    end
  end

  describe "fetch/2 if /download responds non-200" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/subtitles"} ->
            response = %{"data" => [%{"attributes" => %{"files" => [%{"file_id" => 1}]}}]}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(response))

          {"POST", "/api/v1/download"} ->
            Plug.Conn.send_resp(conn, 403, "forbidden")
        end
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:error, {:opensubtitles_status, 403, "forbidden"}} =
               OpenSubtitles.fetch(handle(plug), entry)
    end
  end

  describe "fetch/2 if the SRT URL responds non-200" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/subtitles"} ->
            response = %{"data" => [%{"attributes" => %{"files" => [%{"file_id" => 1}]}}]}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(response))

          {"POST", "/api/v1/download"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"link" => "https://cdn.test/missing.srt"}))

          {"GET", "/missing.srt"} ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:error, {:opensubtitles_status, 404, ""}} = OpenSubtitles.fetch(handle(plug), entry)
    end
  end

  describe "fetch/2 when the handle carries a bearer_token" do
    test "then /download is sent with Authorization: Bearer <token>" do
      test_pid = self()

      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/subtitles"} ->
            response = %{"data" => [%{"attributes" => %{"files" => [%{"file_id" => 1}]}}]}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(response))

          {"POST", "/api/v1/download"} ->
            send(test_pid, {:download_auth, Plug.Conn.get_req_header(conn, "authorization")})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"link" => "https://cdn.test/file.srt"}))

          {"GET", "/file.srt"} ->
            Plug.Conn.send_resp(conn, 200, srt_body())
        end
      end

      authed_handle =
        OpenSubtitles.new(
          api_key: "key-abc",
          user_agent: "jido_watch test",
          bearer_token: "tok-xyz",
          plug: plug
        )

      entry = %{"type" => "movie", "movie" => %{"ids" => %{"imdb" => "tt1234567"}}}

      assert {:ok, _} = OpenSubtitles.fetch(authed_handle, entry)
      assert_received {:download_auth, ["Bearer tok-xyz"]}
    end
  end

  describe "login/3 when given valid credentials" do
    test "then it POSTs username and password to /login and returns the bearer token from the response" do
      test_pid = self()

      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/login"
        assert Plug.Conn.get_req_header(conn, "api-key") == ["key-abc"]
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["jido_watch test"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:login_body, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"token" => "tok-xyz"}))
      end

      assert {:ok, "tok-xyz"} = OpenSubtitles.login(handle(plug), "alice", "hunter2")
      assert_received {:login_body, %{"username" => "alice", "password" => "hunter2"}}
    end
  end

  describe "login/3 if /login responds non-200" do
    test "then the error wraps the status and body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "bad credentials"}))
      end

      assert {:error, {:opensubtitles_status, 401, %{"message" => "bad credentials"}}} =
               OpenSubtitles.login(handle(plug), "alice", "wrong")
    end
  end
end
