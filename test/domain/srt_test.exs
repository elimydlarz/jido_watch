defmodule JidoWatch.Domain.SrtTest do
  use ExUnit.Case, async: true

  @moduletag :domain

  alias JidoWatch.Srt
  alias JidoWatch.Subtitle.Cue

  describe "parse/1" do
    test "then each block becomes a Cue with start_ms and end_ms parsed from the timestamp line" do
      srt = """
      1
      00:00:01,000 --> 00:00:04,000
      First line

      2
      00:00:05,500 --> 00:00:08,250
      Second line
      """

      assert {:ok,
              [
                %Cue{start_ms: 1_000, end_ms: 4_000, text: "First line"},
                %Cue{start_ms: 5_500, end_ms: 8_250, text: "Second line"}
              ]} = Srt.parse(srt)
    end

    test "then multi-line cue text is joined with newlines" do
      srt = """
      1
      00:00:01,000 --> 00:00:02,000
      First
      second
      """

      assert {:ok, [%Cue{text: "First\nsecond"}]} = Srt.parse(srt)
    end

    test "then blocks separated by extra blank lines parse the same as single-blank-separated" do
      srt = "1\n00:00:01,000 --> 00:00:02,000\nA\n\n\n\n2\n00:00:03,000 --> 00:00:04,000\nB\n"

      assert {:ok, [%Cue{text: "A"}, %Cue{text: "B"}]} = Srt.parse(srt)
    end

    test "when given an empty string then no cues are returned" do
      assert {:ok, []} = Srt.parse("")
    end

    test "if a block has a malformed timestamp line then the error wraps the offending block index" do
      srt = "1\nnot a timestamp\nText\n"

      assert {:error, {:malformed_block, 0, _}} = Srt.parse(srt)
    end
  end
end
