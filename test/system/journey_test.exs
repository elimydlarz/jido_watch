defmodule JidoWatch.System.JourneyTest do
  use ExUnit.Case, async: false

  @moduletag :journey

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoWatch.Subtitle.OpenSubtitles
  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Trakt.HTTP

  @required_env ~w(
    TRAKT_CLIENT_ID
    TRAKT_CLIENT_SECRET
    OPENSUBTITLES_API_KEY
    OPENSUBTITLES_USERNAME
    OPENSUBTITLES_PASSWORD
    OPENSUBTITLES_USER_AGENT
  )

  @angles [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads]

  setup_all do
    missing = Enum.filter(@required_env, fn n -> System.get_env(n) in [nil, ""] end)

    if missing != [] do
      raise "Missing env for the journey test: #{Enum.join(missing, ", ")}. Populate .env (see .env.example)."
    end

    :ok
  end

  describe "when the user requests Trakt authorization through user_setup" do
    test "the whole runtime lifecycle: OS login at startup, user_setup, polling, callbacks, re-poll idempotency" do
      trakt_handle =
        HTTP.new(
          client_id: env!("TRAKT_CLIENT_ID"),
          client_secret: env!("TRAKT_CLIENT_SECRET")
        )

      os_handle =
        OpenSubtitles.new(
          api_key: env!("OPENSUBTITLES_API_KEY"),
          user_agent: env!("OPENSUBTITLES_USER_AGENT")
        )

      {:ok, bearer} =
        OpenSubtitles.login(
          os_handle,
          env!("OPENSUBTITLES_USERNAME"),
          env!("OPENSUBTITLES_PASSWORD")
        )

      os_authed =
        OpenSubtitles.new(
          api_key: env!("OPENSUBTITLES_API_KEY"),
          user_agent: env!("OPENSUBTITLES_USER_AGENT"),
          bearer_token: bearer
        )

      {:ok, pid} =
        HostAgent.start_link(
          trakt: {HTTP, trakt_handle},
          subtitles: {OpenSubtitles, os_authed},
          trakt_client_id: env!("TRAKT_CLIENT_ID"),
          trakt_client_secret: env!("TRAKT_CLIENT_SECRET"),
          angles: @angles,
          test_pid: self()
        )

      {:ok, url} = HostAgent.user_setup(pid)

      IO.puts("""

      Open this URL in your browser, authorize on Trakt, then paste the code below.

        #{url}
      """)

      code = "Trakt code: " |> IO.gets() |> to_string() |> String.trim()

      if code == "" do
        flunk("No code entered; aborting journey.")
      end

      :ok = HostAgent.complete_user_setup(pid, code)
      assert HostAgent.connected?(pid)

      {:ok, entries} = HTTP.recent_watches(trakt_handle, current_access_token(pid))

      assert entries != [],
             "No recent Trakt watches found. Watch something on Trakt before running this."

      watermark_for_isolation(pid, entries)

      :ok = HostAgent.poll(pid)

      assert_receive {:watch_called, _}, 60_000
      drain(:watch_called)

      for _ <- @angles do
        assert_receive {:experience_called, _, _}, 60_000
      end

      assert_receive {:form_opinion_called, _}, 60_000

      :ok = HostAgent.poll(pid)

      refute_receive {:watch_called, _}, 5_000
      refute_receive {:experience_called, _, _}, 200
      refute_receive {:form_opinion_called, _}, 200
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      nil -> raise "#{name} not set"
      "" -> raise "#{name} empty"
      value -> value
    end
  end

  defp current_access_token(pid) do
    {:ok, state} = AgentServer.state(pid)
    {:connected, %{access_token: token}} = state.agent.state[:__jido_watch__].connection
    token
  end

  defp watermark_for_isolation(pid, entries) do
    case entries do
      [_first, second | _] ->
        {:ok, dt, _} = DateTime.from_iso8601(second["watched_at"])
        signal = Signal.new!(%{type: "jido_watch.set_watermark", data: %{watermark: dt}})

        case AgentServer.call(pid, signal) do
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp drain(tag) do
    receive do
      {^tag, _} -> drain(tag)
      {^tag, _, _} -> drain(tag)
    after
      0 -> :ok
    end
  end
end
