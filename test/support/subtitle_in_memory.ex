defmodule JidoWatch.Test.Support.SubtitleInMemory do
  @moduledoc """
  In-memory twin of `JidoWatch.Subtitle.Source` for tests.

  Seeded with an `entry_id -> [%Cue{}]` map; `fetch/2` returns the seeded
  cues for matching ids and `{:ok, :no_transcript}` otherwise — mirroring the
  real adapter, where "no English subtitles found" is a non-error outcome.
  """

  @behaviour JidoWatch.Subtitle.Source

  use Agent

  def start!(opts \\ []) do
    cues = Keyword.get(opts, :cues, %{})

    {:ok, pid} = Agent.start_link(fn -> %{cues: cues} end)
    {__MODULE__, pid}
  end

  @impl JidoWatch.Subtitle.Source
  def fetch(pid, entry) do
    id = Map.fetch!(entry, "id")

    case Agent.get(pid, fn state -> Map.get(state.cues, id) end) do
      nil -> {:ok, :no_transcript}
      cues -> {:ok, cues}
    end
  end
end
