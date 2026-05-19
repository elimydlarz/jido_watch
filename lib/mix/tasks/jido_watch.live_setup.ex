defmodule Mix.Tasks.JidoWatch.LiveSetup do
  @shortdoc "Run the Trakt OAuth setup flow end-to-end against the real Trakt API"

  @moduledoc """
  Drives the full `setup_jido_watch` flow against the live Trakt API so you can
  verify the plugin, action and HTTP adapter against the real thing.

  Requires `TRAKT_CLIENT_ID` and `TRAKT_CLIENT_SECRET` in the environment
  (a `.env` file in the project root is loaded automatically if present —
  see `.env.example`).

  The task:

  1. Calls `setup_jido_watch` with no args; prints the Trakt authorization URL.
  2. Waits for you to open the URL, authorize on Trakt, and paste the code back.
  3. Calls `setup_jido_watch` with the code; reports whether the agent is connected.

  Nothing about step 2 is bypassed — that's the human part of the auth flow,
  by design.
  """

  use Mix.Task

  alias Jido.AgentServer
  alias Jido.Signal

  defmodule LiveAgent do
    @moduledoc false
    use Jido.Agent,
      name: "jido_watch_live_setup",
      plugins: [JidoWatch.Plugin]
  end

  @impl Mix.Task
  def run(_argv) do
    load_dotenv()
    Mix.Task.run("app.start")

    client_id = fetch_env!("TRAKT_CLIENT_ID")
    client_secret = fetch_env!("TRAKT_CLIENT_SECRET")
    redirect_uri = System.get_env("TRAKT_REDIRECT_URI", "urn:ietf:wg:oauth:2.0:oob")

    trakt =
      JidoWatch.Trakt.HTTP.new(
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri
      )

    {:ok, pid} =
      AgentServer.start_link(
        agent: LiveAgent,
        register_global: false,
        initial_state: %{
          __jido_watch__: %{
            trakt: {JidoWatch.Trakt.HTTP, trakt},
            trakt_client_id: client_id,
            trakt_client_secret: client_secret,
            redirect_uri: redirect_uri
          }
        }
      )

    {:ok, url} = call_setup(pid, %{})

    IO.puts("""

    Open this URL in your browser, authorize the app on Trakt, then paste the
    code back below.

      #{url}
    """)

    code = "Trakt code: " |> IO.gets() |> to_string() |> String.trim()

    if code == "" do
      Mix.raise("No code entered; aborting.")
    end

    case call_setup(pid, %{code: code}) do
      {:ok, _url} ->
        connection = connection(pid)

        case connection do
          {:connected, tokens} ->
            IO.puts("\n✓ Connected to Trakt.\n")
            print_token_block(tokens)

          _ ->
            Mix.raise("Token exchange returned without an error but the agent is not connected.")
        end

      {:error, reason} ->
        Mix.raise("Token exchange failed: #{inspect(reason)}")
    end
  end

  defp print_token_block(%{access_token: access, refresh_token: refresh, expires_in: expires_in}) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    IO.puts("""
    Add these to your .env to enable the live journey test
    (mix test.journey). They expire #{expires_at}; rerun this task before then.

    TRAKT_ACCESS_TOKEN=#{access}
    TRAKT_REFRESH_TOKEN=#{refresh}
    TRAKT_TOKEN_EXPIRES_AT=#{expires_at}
    """)
  end

  defp call_setup(pid, data) do
    signal = Signal.new!(%{type: "jido_watch.setup_jido_watch", data: data})

    case AgentServer.call(pid, signal) do
      {:ok, agent} ->
        plugin_state = agent.state[:__jido_watch__]

        case plugin_state.last_setup_error do
          nil -> {:ok, plugin_state.last_setup_url}
          reason -> {:error, reason}
        end

      other ->
        other
    end
  end

  defp connected?(pid) do
    {:ok, state} = AgentServer.state(pid)
    match?({:connected, _}, state.agent.state[:__jido_watch__].connection)
  end

  defp fetch_env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("#{name} is not set. Copy .env.example to .env and fill it in.")
      "" -> Mix.raise("#{name} is empty. Set it in your environment or .env file.")
      value -> value
    end
  end

  defp load_dotenv do
    path = Path.join(File.cwd!(), ".env")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(&apply_dotenv_line/1)
    end
  end

  defp apply_dotenv_line(line) do
    case String.trim(line) do
      "" ->
        :ok

      "#" <> _ ->
        :ok

      trimmed ->
        case String.split(trimmed, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = value |> String.trim() |> strip_quotes()

            if System.get_env(key) in [nil, ""] do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
    end
  end

  defp strip_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end
end
