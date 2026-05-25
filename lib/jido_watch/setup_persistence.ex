defmodule JidoWatch.SetupPersistence do
  @moduledoc """
  Reads and writes the operator-setup file produced by `mix jido_watch.setup`.

  The plugin reads this file on mount and on restore to obtain the
  pre-authenticated OpenSubtitles bearer token, so the operator only runs the
  mix command once and the plugin survives agent hibernate/thaw cycles.

  Path precedence: `JIDO_WATCH_SETUP_FILE` env var, else
  `~/.jido_watch/setup.json`.
  """

  @default_dir Path.join(System.user_home!(), ".jido_watch")
  @default_file Path.join(@default_dir, "setup.json")

  @typedoc "Parsed setup file contents."
  @type t :: %{
          optional(:opensubtitles_bearer) => String.t(),
          optional(:logged_in_at) => String.t()
        }

  @doc """
  Returns the path the setup file lives at, without creating anything on disk.
  """
  @spec path :: String.t()
  def path do
    System.get_env("JIDO_WATCH_SETUP_FILE") || @default_file
  end

  @doc """
  Reads and decodes the setup file. Returns `{:ok, map}` or `{:error, reason}`.

  Returns `{:ok, %{}}` when the file does not exist — the consuming code treats
  a missing file as "the operator hasn't run setup yet," not as a crash.
  """
  @spec read :: {:ok, t()} | {:error, term()}
  def read do
    p = path()

    case File.read(p) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:error, _} = err -> err
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Persists an OpenSubtitles bearer token to the setup file, creating the parent
  directory if needed.
  """
  @spec write_bearer(String.t()) :: :ok | {:error, term()}
  def write_bearer(bearer) when is_binary(bearer) do
    {:ok, existing} = read()

    updated =
      existing
      |> Map.put("opensubtitles_bearer", bearer)
      |> Map.put("logged_in_at", DateTime.utc_now() |> DateTime.to_iso8601())

    write(updated)
  end

  defp write(map) when is_map(map) do
    p = path()

    with :ok <- File.mkdir_p(Path.dirname(p)),
         :ok <- File.write(p, Jason.encode!(map)) do
      :ok
    end
  end
end
