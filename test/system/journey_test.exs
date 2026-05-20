defmodule JidoWatch.System.JourneyTest do
  use ExUnit.Case, async: false

  @moduletag :journey

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
    test "the whole runtime lifecycle: OS login at startup, user_setup, polling new content, callbacks, re-poll idempotency" do
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

      IO.puts("""

      OpenSubtitles login OK — bearer #{redact(bearer)}
      """)

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

      Step 1 — Open this URL in your browser, authorize on Trakt, paste the code back below:

        #{url}
      """)

      code = "Trakt code: " |> IO.gets() |> to_string() |> String.trim()
      assert code != "", "No code entered; aborting journey."

      :ok = HostAgent.complete_user_setup(pid, code)
      assert HostAgent.connected?(pid)

      IO.puts("""

      Step 2 — Mark a movie or episode as watched on Trakt right now
      (e.g. https://trakt.tv/movies — pick something popular with subtitles
      on OpenSubtitles). Then press enter to continue.
      """)

      _ = IO.gets("Press enter when watched: ")

      diagnose_pipeline(pid, trakt_handle, os_authed)

      :ok = HostAgent.poll(pid)

      assert_receive {:watch_called, first_chunk}, 60_000
      chunks = collect_watch_called([first_chunk])
      report_trakt_and_chunks(chunks)

      experiences =
        for _ <- @angles do
          assert_receive {:experience_called, angle, experiences}, 60_000
          {angle, experiences}
        end

      report_experiences(experiences)

      assert_receive {:form_opinion_called, impressions}, 60_000
      report_impressions(impressions)

      IO.puts("\nRe-polling to verify idempotency — no callbacks should fire below.\n")

      :ok = HostAgent.poll(pid)

      refute_receive {:watch_called, _}, 5_000
      refute_receive {:experience_called, _, _}, 200
      refute_receive {:form_opinion_called, _}, 200

      IO.puts("Re-poll produced no new callbacks. Journey OK.\n")
    end
  end

  defp redact(token) when is_binary(token) and byte_size(token) > 8,
    do: binary_part(token, 0, 4) <> "…" <> binary_part(token, byte_size(token) - 4, 4)

  defp redact(_), do: "<short>"

  defp collect_watch_called(acc) do
    receive do
      {:watch_called, chunk} -> collect_watch_called([chunk | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  defp report_trakt_and_chunks(chunks) do
    [%{watch: watch} | _] = chunks

    IO.puts("""

    Trakt /sync/history returned the entry being processed:
      type:       #{inspect(watch["type"])}
      watched_at: #{inspect(watch["watched_at"])}
      title:      #{inspect(title_of(watch))}
      ids:        #{inspect(ids_of(watch))}

    OpenSubtitles returned cues; the plugin chunked them into #{length(chunks)} window(s) and called watch/2 once per chunk:
    """)

    Enum.each(chunks, fn chunk ->
      IO.puts(
        "  chunk #{chunk.index} (#{chunk.start_ms}..#{chunk.end_ms}ms, #{length(chunk.cues)} cues) — first cue: #{first_cue_excerpt(chunk.cues)}"
      )
    end)
  end

  defp report_experiences(experiences) do
    IO.puts("\nexperience/3 was called once per angle (parallel); each got #{experiences |> hd() |> elem(1) |> length()} experience(s):")

    Enum.each(experiences, fn {angle, exps} ->
      IO.puts("  #{angle}: #{inspect(Enum.map(exps, & &1.data))}")
    end)
  end

  defp report_impressions(impressions) do
    IO.puts("\nform_opinion/2 was called once with #{length(impressions)} impression(s):")

    Enum.each(impressions, fn imp ->
      IO.puts("  #{imp.angle}: #{inspect(imp.data)}")
    end)
  end

  defp title_of(%{"type" => "movie", "movie" => %{"title" => t}}), do: t
  defp title_of(%{"type" => "episode", "show" => %{"title" => t}}), do: t
  defp title_of(_), do: nil

  defp ids_of(%{"type" => "movie", "movie" => %{"ids" => ids}}), do: ids
  defp ids_of(%{"type" => "episode", "episode" => %{"ids" => ids}}), do: ids
  defp ids_of(_), do: nil

  defp first_cue_excerpt([]), do: "(no cues)"

  defp first_cue_excerpt([%{text: text} | _]) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.slice(0, 80)
    |> inspect()
  end

  defp env!(name) do
    case System.get_env(name) do
      nil -> raise "#{name} not set"
      "" -> raise "#{name} empty"
      value -> value
    end
  end

end
