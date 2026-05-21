defmodule JidoWatch.Watching do
  @moduledoc """
  The watching pipeline. Every tick does the same thing regardless of state:

    1. Fetch recent history from Trakt.
    2. Add any entry past the watermark to `pending_watches`, deduped by Trakt
       entry id.
    3. Attempt every entry on `pending_watches` through the watching pipeline.
    4. Drop the ones that were successfully processed (the agent's
       `form_opinion/2` was called); keep the rest for the next tick.

  Watermark advances to the latest `watched_at` returned by Trakt this tick —
  it only tracks "how far back in Trakt's history we've already looked at".
  Per-entry retry is decided by membership in `pending_watches`, not by the
  watermark.

  For each pending entry, the pipeline drives the agent's three callbacks:

    1. `watch/2` once per chunk, in window order, sequentially.
    2. `experience/3` once per configured angle, in parallel, with the full
       list of chunk-experiences.
    3. `form_opinion/2` once with the per-angle impressions.

  The pipeline never sees the LLM, the system prompt, or the delivery channel
  — those live inside the host's callback implementations.
  """

  alias Jido.Agent
  alias JidoWatch.Chunker

  @type entry :: map()
  @type result :: %{watermark: DateTime.t() | nil, pending_watches: [entry]}

  @spec run(map()) :: {:ok, result()} | {:error, term()}
  def run(%{
        trakt: {trakt_mod, trakt_handle},
        subtitles: subtitles,
        access_token: access_token,
        host: host,
        agent: %Agent{} = agent,
        angles: angles
      } = opts) do
    watermark = Map.get(opts, :watermark)
    pending = Map.get(opts, :pending_watches, [])

    case trakt_mod.recent_watches(trakt_handle, access_token) do
      {:ok, entries} ->
        fresh = Enum.filter(entries, &past_watermark?(&1, watermark))
        next_pending = merge_pending(pending, fresh)

        remaining =
          Enum.reject(next_pending, fn entry ->
            processed?(entry, subtitles, host, agent, angles)
          end)

        new_watermark = advance_watermark(watermark, fresh)
        {:ok, %{watermark: new_watermark, pending_watches: remaining}}

      {:error, _} = err ->
        err
    end
  end

  defp merge_pending(pending, fresh) do
    existing_ids = MapSet.new(pending, &entry_id/1)
    new_entries = Enum.reject(fresh, &MapSet.member?(existing_ids, entry_id(&1)))
    pending ++ new_entries
  end

  defp entry_id(%{"id" => id}), do: id

  defp processed?(entry, {sub_mod, sub_handle}, host, agent, angles) do
    case sub_mod.fetch(sub_handle, entry) do
      {:ok, :no_transcript} ->
        false

      {:ok, cues} ->
        chunks = Chunker.chunk_for_watch(entry, cues)

        with {:ok, experiences} <- watch_each(host, agent, chunks),
             {:ok, impressions} <- experience_each(host, agent, experiences, angles),
             :ok <- host.form_opinion(agent, impressions) do
          true
        else
          _ -> false
        end

      {:error, _} ->
        false
    end
  end

  defp advance_watermark(watermark, fresh) do
    Enum.reduce(fresh, watermark, fn entry, acc ->
      case watched_at(entry) do
        nil -> acc
        %DateTime{} = at -> max_dt(acc, at)
      end
    end)
  end

  defp max_dt(nil, b), do: b

  defp max_dt(a, b) do
    case DateTime.compare(a, b) do
      :lt -> b
      _ -> a
    end
  end

  defp past_watermark?(_entry, nil), do: true

  defp past_watermark?(entry, watermark) do
    case watched_at(entry) do
      nil -> true
      %DateTime{} = at -> DateTime.compare(at, watermark) == :gt
    end
  end

  defp watched_at(%{"watched_at" => binary}) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp watched_at(_), do: nil

  defp watch_each(host, agent, chunks) do
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case host.watch(agent, chunk) do
        {:ok, experience} -> {:cont, {:ok, acc ++ [experience]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp experience_each(host, agent, experiences, angles) do
    angles
    |> Task.async_stream(fn angle -> host.experience(agent, experiences, angle) end,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, impression}}, {:ok, acc} -> {:cont, {:ok, acc ++ [impression]}}
      {:ok, {:error, _} = err}, _ -> {:halt, err}
    end)
  end
end
