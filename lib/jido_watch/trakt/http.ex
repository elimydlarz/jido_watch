defmodule JidoWatch.Trakt.HTTP do
  @moduledoc """
  Real `JidoWatch.Trakt.Client` adapter that talks to the live Trakt API.

  Construct with `new/1` and store the returned struct in plugin state as the
  `:trakt` value: `{JidoWatch.Trakt.HTTP, handle}`.
  """

  @behaviour JidoWatch.Trakt.Client

  defstruct [:client_id, :client_secret, :redirect_uri, :base_url, :plug]

  @default_base_url "https://api.trakt.tv"
  @default_redirect_uri "urn:ietf:wg:oauth:2.0:oob"

  def new(opts) do
    %__MODULE__{
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      redirect_uri: Keyword.get(opts, :redirect_uri, @default_redirect_uri),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      plug: Keyword.get(opts, :plug)
    }
  end

  @impl JidoWatch.Trakt.Client
  def exchange_code(%__MODULE__{} = handle, code) do
    body = %{
      code: code,
      client_id: handle.client_id,
      client_secret: handle.client_secret,
      redirect_uri: handle.redirect_uri,
      grant_type: "authorization_code"
    }

    case Req.post(handle.base_url <> "/oauth/token", [json: body] ++ req_opts(handle)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: Map.fetch!(body, "access_token"),
           refresh_token: Map.fetch!(body, "refresh_token"),
           expires_in: Map.fetch!(body, "expires_in")
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:trakt_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl JidoWatch.Trakt.Client
  def recent_watches(%__MODULE__{} = handle, access_token) do
    headers = [
      {"authorization", "Bearer " <> access_token},
      {"trakt-api-version", "2"},
      {"trakt-api-key", handle.client_id}
    ]

    case Req.get(handle.base_url <> "/sync/history", [headers: headers] ++ req_opts(handle)) do
      {:ok, %Req.Response{status: 200, body: entries}} when is_list(entries) ->
        {:ok, entries}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:trakt_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp req_opts(%__MODULE__{plug: nil}), do: []
  defp req_opts(%__MODULE__{plug: plug}), do: [plug: plug]
end
