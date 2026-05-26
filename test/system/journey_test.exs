defmodule JidoWatch.System.JourneyTest do
  use ExUnit.Case, async: false

  @moduletag :journey

  alias Jido.AgentServer
  alias Jido.Persist
  alias Jido.Storage.ETS, as: EtsStorage
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
    test "the whole runtime lifecycle: OS login at startup, user_setup, polling new content, callbacks, re-poll idempotency, hibernate-and-thaw preserves durable cursors" do
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

      profile = HostAgent.viewing_profile(pid)
      assert %JidoWatch.ViewingProfile{} = profile
      report_profile(profile)

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

      IO.puts(
        "Verifying persistence — hibernate, stop, thaw, re-poll should remain idempotent.\n"
      )

      {:ok, server_state} = AgentServer.state(pid)
      pre_hibernate = server_state.agent.state[:__jido_watch__]

      storage = {EtsStorage, [table: :jido_watch_journey_storage]}
      persistence_key = "journey-test-agent"

      :ok = Persist.hibernate(storage, HostAgent, persistence_key, server_state.agent)
      :ok = GenServer.stop(pid)

      {:ok, restored_agent} = Persist.thaw(storage, HostAgent, persistence_key)
      restored_slice = restored_agent.state[:__jido_watch__]

      assert restored_slice.connection == pre_hibernate.connection
      assert restored_slice.watermark == pre_hibernate.watermark
      assert restored_slice.pending_watches == pre_hibernate.pending_watches

      rewired_slice =
        Map.merge(restored_slice, %{
          trakt: {HTTP, trakt_handle},
          subtitles: {OpenSubtitles, os_authed},
          trakt_client_id: env!("TRAKT_CLIENT_ID"),
          trakt_client_secret: env!("TRAKT_CLIENT_SECRET"),
          angles: @angles
        })

      rewired_agent = %{
        restored_agent
        | state:
            restored_agent.state
            |> Map.put(:__jido_watch__, rewired_slice)
            |> Map.put(:test_pid, self())
      }

      {:ok, pid2} = AgentServer.start_link(agent: rewired_agent, register_global: false)
      on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

      :ok = HostAgent.poll(pid2)

      refute_receive {:watch_called, _}, 5_000
      refute_receive {:experience_called, _, _}, 200
      refute_receive {:form_opinion_called, _}, 200

      IO.puts("Thawed-agent poll produced no new callbacks. Persistence OK.\n")
    end
  end

  defp report_profile(profile) do
    top_genres =
      profile.genre_distribution
      |> Enum.sort_by(fn {_genre, count} -> count end, :desc)
      |> Enum.take(5)

    IO.puts("""

    Viewing profile built from your Trakt backlog at connection time:
      shows watched:    #{profile.shows_watched}
      movies watched:   #{profile.movies_watched}
      episodes watched: #{profile.episodes_watched}
      top genres:       #{inspect(top_genres)}
      most watched:     #{inspect(Enum.take(profile.most_watched_shows, 5))}
      recent:           #{inspect(Enum.take(profile.recently_watched, 5))}
    """)
  end

  defp diagnose_pipeline(pid, trakt_handle, os_handle) do
    {:ok, access_token} = HostAgent.access_token(pid)
    watermark = HostAgent.watermark(pid)

    IO.puts("""

    --- Pipeline pre-flight diagnostic ---
    Plugin watermark: #{inspect(watermark)}
    Calling Trakt /sync/history with the stored access token…
    """)

    case HTTP.recent_watches(trakt_handle, access_token) do
      {:ok, []} ->
        IO.puts(
          "  Trakt returned 0 entries. The watch you marked hasn't propagated yet — wait a few seconds and re-run, or check trakt.tv/users/me/history."
        )

      {:ok, entries} ->
        IO.puts("  Trakt returned #{length(entries)} entries (newest first).")

        Enum.each(entries, fn entry ->
          past? = entry_past_watermark?(entry, watermark)
          marker = if past?, do: "→ will process", else: "✗ before watermark"

          IO.puts(
            "  #{marker}: type=#{inspect(entry["type"])} watched_at=#{entry["watched_at"]} title=#{inspect(title_of(entry))}"
          )
        end)

        entries
        |> Enum.filter(&entry_past_watermark?(&1, watermark))
        |> case do
          [] ->
            IO.puts("  No entries past the watermark — poll will fire no callbacks.")

          past ->
            IO.puts("\n  Trying OpenSubtitles.fetch for each past-watermark entry:")

            Enum.each(past, fn entry ->
              case OpenSubtitles.fetch(os_handle, entry) do
                {:ok, cues} ->
                  IO.puts(
                    "    ok #{inspect(title_of(entry))}: #{length(cues)} cues (first: #{first_cue_excerpt(cues)})"
                  )

                {:error, reason} ->
                  IO.puts("    error #{inspect(title_of(entry))}: #{inspect(reason)}")
              end
            end)
        end

      {:error, reason} ->
        IO.puts("  Trakt error: #{inspect(reason)}")
    end

    IO.puts("--- End diagnostic ---\n")
  end

  defp entry_past_watermark?(_entry, nil), do: true

  defp entry_past_watermark?(%{"watched_at" => watched_at}, watermark)
       when is_binary(watched_at) do
    case DateTime.from_iso8601(watched_at) do
      {:ok, dt, _} -> DateTime.compare(dt, watermark) == :gt
      _ -> true
    end
  end

  defp entry_past_watermark?(_, _), do: true

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
    IO.puts(
      "\nexperience/3 was called once per angle (parallel); each got #{experiences |> hd() |> elem(1) |> length()} experience(s):"
    )

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
