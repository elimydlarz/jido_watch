defmodule JidoWatch.System.JourneyTest do
  use ExUnit.Case, async: false

  @moduletag :journey

  alias JidoWatch.Subtitle.OpenSubtitles
  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Trakt.HTTP

  @required_env ~w(
    TRAKT_CLIENT_ID
    TRAKT_CLIENT_SECRET
    TRAKT_ACCESS_TOKEN
    TRAKT_REFRESH_TOKEN
    OPENSUBTITLES_API_KEY
    OPENSUBTITLES_USERNAME
    OPENSUBTITLES_PASSWORD
    OPENSUBTITLES_USER_AGENT
  )

  @angles [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads]

  setup_all do
    missing =
      Enum.filter(@required_env, fn name -> System.get_env(name) in [nil, ""] end)

    if missing != [] do
      raise """
      Missing env for the journey test: #{Enum.join(missing, ", ")}.
      Populate .env (see .env.example), run `mix jido_watch.live_setup` for the Trakt tokens,
      then rerun with `mix test.journey`.
      """
    end

    :ok
  end

  describe "when a connected user polls Trakt and the most recent entry has retrievable subtitles" do
    test "then watch/2, experience/3 (per angle), and form_opinion/2 are invoked, and a re-poll fires nothing" do
      trakt_handle =
        HTTP.new(
          client_id: env!("TRAKT_CLIENT_ID"),
          client_secret: env!("TRAKT_CLIENT_SECRET")
        )

      access_token = env!("TRAKT_ACCESS_TOKEN")

      {:ok, entries} = HTTP.recent_watches(trakt_handle, access_token)

      assert entries != [],
             "No recent Trakt watches found. Mark something as watched on Trakt before running this test."

      watermark =
        case entries do
          [_first, second | _] ->
            {:ok, dt, _} = DateTime.from_iso8601(second["watched_at"])
            dt

          _ ->
            nil
        end

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

      tokens = %{
        access_token: access_token,
        refresh_token: env!("TRAKT_REFRESH_TOKEN"),
        expires_in: 0
      }

      {:ok, pid} =
        HostAgent.start_link(
          trakt: {HTTP, trakt_handle},
          subtitles: {OpenSubtitles, os_authed},
          trakt_client_id: env!("TRAKT_CLIENT_ID"),
          trakt_client_secret: env!("TRAKT_CLIENT_SECRET"),
          connection: {:connected, tokens},
          watermark: watermark,
          angles: @angles,
          test_pid: self()
        )

      :ok = HostAgent.poll(pid)

      assert_receive {:watch_called, _}, 30_000
      drain(:watch_called)

      for _ <- @angles do
        assert_receive {:experience_called, _, _}, 30_000
      end

      assert_receive {:form_opinion_called, _}, 30_000

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

  defp drain(tag) do
    receive do
      {^tag, _} -> drain(tag)
      {^tag, _, _} -> drain(tag)
    after
      0 -> :ok
    end
  end
end
