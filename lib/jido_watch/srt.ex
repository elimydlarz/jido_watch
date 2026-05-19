defmodule JidoWatch.Srt do
  @moduledoc """
  Parses SRT subtitle content into `JidoWatch.Subtitle.Cue` structs.
  """

  alias JidoWatch.Subtitle.Cue

  @spec parse(binary()) :: {:ok, [Cue.t()]} | {:error, term()}
  def parse(srt) when is_binary(srt) do
    srt
    |> String.split(~r/\r?\n\r?\n+/, trim: true)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {block, idx}, {:ok, acc} ->
      case parse_block(block) do
        {:ok, cue} -> {:cont, {:ok, [cue | acc]}}
        {:error, reason} -> {:halt, {:error, {:malformed_block, idx, reason}}}
      end
    end)
    |> case do
      {:ok, cues} -> {:ok, Enum.reverse(cues)}
      err -> err
    end
  end

  defp parse_block(block) do
    lines = String.split(block, ~r/\r?\n/, trim: true)

    with [_index_line, timestamp_line | text_lines] <- lines,
         {:ok, start_ms, end_ms} <- parse_timestamp(timestamp_line) do
      {:ok, %Cue{start_ms: start_ms, end_ms: end_ms, text: Enum.join(text_lines, "\n")}}
    else
      _ -> {:error, :malformed_timestamp}
    end
  end

  defp parse_timestamp(line) do
    case String.split(line, " --> ", trim: true) do
      [start_part, end_part] ->
        with {:ok, start_ms} <- parse_time(start_part),
             {:ok, end_ms} <- parse_time(end_part) do
          {:ok, start_ms, end_ms}
        end

      _ ->
        {:error, :malformed_timestamp}
    end
  end

  defp parse_time(str) do
    case Regex.run(~r/^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$/, String.trim(str)) do
      [_, h, m, s, ms] ->
        {:ok,
         String.to_integer(h) * 3_600_000 + String.to_integer(m) * 60_000 +
           String.to_integer(s) * 1_000 + String.to_integer(ms)}

      _ ->
        {:error, :malformed_timestamp}
    end
  end
end
