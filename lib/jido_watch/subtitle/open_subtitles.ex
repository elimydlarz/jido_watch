defmodule JidoWatch.Subtitle.OpenSubtitles do
  @moduledoc """
  `JidoWatch.Subtitle.Source` adapter that fetches and parses subtitles from
  the OpenSubtitles REST API (`/api/v1/subtitles` → `/api/v1/download` → SRT
  URL).

  Construct with `new/1` and pair the returned struct with this module in
  plugin state as `{JidoWatch.Subtitle.OpenSubtitles, handle}`.
  """

  @behaviour JidoWatch.Subtitle.Source

  alias JidoWatch.Srt

  defstruct [:api_key, :user_agent, :base_url, :bearer_token, :plug]

  @default_base_url "https://api.opensubtitles.com/api/v1"

  def new(opts) do
    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      user_agent: Keyword.fetch!(opts, :user_agent),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      bearer_token: Keyword.get(opts, :bearer_token),
      plug: Keyword.get(opts, :plug)
    }
  end

  @spec login(t :: %__MODULE__{}, binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def login(%__MODULE__{} = handle, username, password) do
    url = handle.base_url <> "/login"
    body = %{username: username, password: password}

    case Req.post(url, [headers: headers(handle), json: body] ++ req_opts(handle)) do
      {:ok, %Req.Response{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:opensubtitles_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl JidoWatch.Subtitle.Source
  def fetch(%__MODULE__{} = handle, watch_entry) do
    with {:ok, imdb_id} <- extract_imdb_id(watch_entry),
         {:ok, file_id_or_no_transcript} <- search(handle, imdb_id) do
      case file_id_or_no_transcript do
        :no_transcript ->
          {:ok, :no_transcript}

        file_id ->
          with {:ok, link} <- request_download(handle, file_id),
               {:ok, srt} <- download(handle, link),
               {:ok, cues} <- Srt.parse(srt) do
            {:ok, cues}
          end
      end
    end
  end

  defp extract_imdb_id(%{"type" => "movie", "movie" => %{"ids" => %{"imdb" => id}}}),
    do: {:ok, id}

  defp extract_imdb_id(%{"type" => "episode", "episode" => %{"ids" => %{"imdb" => id}}}),
    do: {:ok, id}

  defp search(handle, imdb_id) do
    url = handle.base_url <> "/subtitles"
    params = [imdb_id: imdb_id, languages: "en"]

    case Req.get(url, [headers: headers(handle), params: params] ++ req_opts(handle)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => []}}} ->
        {:error, :no_subtitles}

      {:ok, %Req.Response{status: 200, body: %{"data" => [first | _]}}} ->
        {:ok, get_in(first, ["attributes", "files", Access.at(0), "file_id"])}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:opensubtitles_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp request_download(handle, file_id) do
    url = handle.base_url <> "/download"

    case Req.post(url,
           [headers: download_headers(handle), json: %{file_id: file_id}] ++ req_opts(handle)
         ) do
      {:ok, %Req.Response{status: 200, body: %{"link" => link}}} ->
        {:ok, link}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:opensubtitles_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp download(handle, link) do
    case Req.get(link, req_opts(handle)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:opensubtitles_status, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp headers(handle) do
    [
      {"api-key", handle.api_key},
      {"user-agent", handle.user_agent},
      {"accept", "application/json"}
    ]
  end

  defp download_headers(%__MODULE__{bearer_token: nil} = handle), do: headers(handle)

  defp download_headers(%__MODULE__{bearer_token: token} = handle),
    do: [{"authorization", "Bearer " <> token} | headers(handle)]

  defp req_opts(%__MODULE__{plug: nil}), do: []
  defp req_opts(%__MODULE__{plug: plug}), do: [plug: plug]
end
