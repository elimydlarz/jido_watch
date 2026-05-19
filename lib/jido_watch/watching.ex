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

  @spec run(map()) :: :ok | {:error, term()}
  def run(%{
        trakt: {trakt_mod, trakt_handle},
        subtitles: {sub_mod, sub_handle},
        access_token: access_token,
        host: host,
        agent: %Agent{} = agent,
        angles: angles
      }) do
    {:ok, entries} = trakt_mod.recent_watches(trakt_handle, access_token)
    Enum.each(entries, &run_for_entry(&1, sub_mod, sub_handle, host, agent, angles))
    :ok
  end

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
