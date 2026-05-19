defmodule JidoWatch.Chunker do
  @moduledoc """
  Slices subtitle cues into fixed-width attention windows for a watch entry.
  """

  alias JidoWatch.Chunk
  alias JidoWatch.Subtitle.Cue

  @window_ms 10 * 60_000

  @spec chunk_for_watch(map(), [Cue.t()]) :: [Chunk.t()]
  def chunk_for_watch(watch, cues) do
    cues
    |> Enum.group_by(fn cue -> div(cue.start_ms, @window_ms) end)
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {index, window_cues} ->
      %Chunk{
        watch: watch,
        index: index,
        start_ms: index * @window_ms,
        end_ms: (index + 1) * @window_ms,
        cues: Enum.sort_by(window_cues, & &1.start_ms)
      }
    end)
  end
end
