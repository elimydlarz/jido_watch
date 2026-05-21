defmodule JidoWatch.Adapter.TraktHTTPTest do
  use ExUnit.Case, async: true

  @moduletag :adapter

  alias JidoWatch.Trakt.HTTP

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
end
