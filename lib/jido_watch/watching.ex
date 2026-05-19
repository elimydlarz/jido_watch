defmodule JidoWatch.Watching do
  @moduledoc """
  The watching pipeline. Fetches new watches from Trakt, fetches subtitles for
  each, chunks the cues, then drives the agent's three callbacks:

    1. `watch/2` once per chunk, in window order, sequentially.
    2. `experience/3` once per configured angle, in parallel, with the full
       list of chunk-experiences.
    3. `form_opinion/2` once with the per-angle impressions.

  The pipeline never sees the LLM, the system prompt, or the delivery channel
  — those live inside the host's callback implementations.
  """

  alias Jido.Agent
  alias JidoWatch.Chunker

  @spec run(map()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def run(%{
        trakt: {trakt_mod, trakt_handle},
        subtitles: {sub_mod, sub_handle},
        access_token: access_token,
        host: host,
        agent: %Agent{} = agent,
        angles: angles
      } = opts) do
    watermark = Map.get(opts, :watermark)
    {:ok, entries} = trakt_mod.recent_watches(trakt_handle, access_token)

    attempted = Enum.filter(entries, &past_watermark?(&1, watermark))
    Enum.each(attempted, &run_for_entry(&1, sub_mod, sub_handle, host, agent, angles))

    {:ok, advance_watermark(watermark, attempted)}
  end

  defp advance_watermark(watermark, attempted) do
    Enum.reduce(attempted, watermark, fn entry, acc ->
      case watched_at(entry) do
        nil -> acc
        %DateTime{} = at -> max_dt(acc, at)
      end
    end)
  end

  defp max_dt(nil, b), do: b
  defp max_dt(a, nil), do: a

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

  defp run_for_entry(entry, sub_mod, sub_handle, host, agent, angles) do
    with {:ok, cues} <- sub_mod.fetch(sub_handle, entry),
         chunks = Chunker.chunk_for_watch(entry, cues),
         {:ok, experiences} <- watch_each(host, agent, chunks),
         {:ok, impressions} <- experience_each(host, agent, experiences, angles) do
      host.form_opinion(agent, impressions)
    end
  end

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
