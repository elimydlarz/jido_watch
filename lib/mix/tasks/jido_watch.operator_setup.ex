defmodule Mix.Tasks.JidoWatch.OperatorSetup do
  @moduledoc """
  One-time operator setup for the JidoWatch viewer plugin.

  Reads Trakt and OpenSubtitles credentials from `.env`, validates them, logs
  into OpenSubtitles to obtain a bearer token, and persists the token so the
  plugin can pick it up at mount/restore time without the consuming app
  needing to call `OpenSubtitles.login/3` itself.

  ## Usage

      mix jido_watch.operator_setup

  Required `.env` vars:

      TRAKT_CLIENT_ID         — Trakt API app client id
      TRAKT_CLIENT_SECRET     — Trakt API app client secret
      OPENSUBTITLES_API_KEY   — OpenSubtitles consumer API key
      OPENSUBTITLES_USERNAME  — OpenSubtitles account username
      OPENSUBTITLES_PASSWORD  — OpenSubtitles account password
      OPENSUBTITLES_USER_AGENT — registered consumer user-agent string

  The OpenSubtitles bearer is persisted to `~/.jido_watch/setup.json` (or
  `$JIDO_WATCH_SETUP_FILE` if set). The plugin reads this file on every mount
  and on every `on_restore/2` so the bearer survives agent hibernate/thaw
  cycles.

  All variables are optional in the sense that if one is missing, the command
  tells you which and exits — it never writes partial state.
  """

  use Mix.Task

  alias JidoWatch.SetupPersistence
  alias JidoWatch.Subtitle.OpenSubtitles

  @required_env ~w(
    TRAKT_CLIENT_ID
    TRAKT_CLIENT_SECRET
    OPENSUBTITLES_API_KEY
    OPENSUBTITLES_USERNAME
    OPENSUBTITLES_PASSWORD
    OPENSUBTITLES_USER_AGENT
  )

  @shortdoc "One-time operator setup: validate Trakt+OpenSubtitles creds and persist a bearer token"
  def run(_args) do
    Application.ensure_all_started(:req)

    env = load_dotenv()
    validate!(env)
    bearer = login_opensubtitles!(env)
    persist!(bearer)

    Mix.shell().info("""

    Operator setup complete.

      Trakt client:      #{env["TRAKT_CLIENT_ID"] |> String.slice(0, 12)}...
      OpenSubtitles:     authenticated
      Bearer persisted:  #{SetupPersistence.path()}

    The plugin will pick up the bearer at the next mount/restore.
    """)
  end

  defp load_dotenv do
    case File.read(".env") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          trimmed = String.trim(line)

          if trimmed == "" or String.starts_with?(trimmed, "#") do
            acc
          else
            case String.split(trimmed, "=", parts: 2) do
              [k, v] ->
                Map.put(acc, String.trim(k), v |> String.trim() |> String.trim(~s(")))

              _ ->
                acc
            end
          end
        end)

      {:error, :enoent} ->
        Mix.shell().error("No .env file found in the current directory.")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Could not read .env: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp validate!(env) do
    missing = Enum.reject(@required_env, &env[&1])

    unless missing == [] do
      Mix.shell().error("""
      Missing required environment variables in .env:

          #{Enum.join(missing, "\n    ")}

      Set them and re-run: mix jido_watch.operator_setup
      """)

      exit({:shutdown, 1})
    end
  end

  defp login_opensubtitles!(env) do
    handle =
      OpenSubtitles.new(
        api_key: env["OPENSUBTITLES_API_KEY"],
        user_agent: env["OPENSUBTITLES_USER_AGENT"]
      )

    Mix.shell().info("Logging into OpenSubtitles...")

    case OpenSubtitles.login(handle, env["OPENSUBTITLES_USERNAME"], env["OPENSUBTITLES_PASSWORD"]) do
      {:ok, bearer} ->
        bearer

      {:error, {:opensubtitles_status, status, body}} ->
        Mix.shell().error("OpenSubtitles login failed (HTTP #{status}): #{inspect(body)}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("OpenSubtitles login failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp persist!(bearer) do
    case SetupPersistence.write_bearer(bearer) do
      :ok -> :ok
      {:error, reason} ->
        Mix.shell().error("Failed to persist bearer: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
