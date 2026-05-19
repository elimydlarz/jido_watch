defmodule JidoWatch.Domain.ChunkerTest do
  use ExUnit.Case, async: true

  @moduletag :domain

  alias JidoWatch.Chunker
  alias JidoWatch.Subtitle.Cue

  describe "chunk_for_watch/2" do
    test "then a cue is placed in the chunk whose 10-minute window contains its start_ms" do
      cue = %Cue{start_ms: 12 * 60_000 + 500, end_ms: 12 * 60_000 + 1_500, text: "x"}

      assert [%{index: 1, cues: [^cue]}] = Chunker.chunk_for_watch(%{"id" => "e"}, [cue])
    end

    test "then cues falling in the same window appear in the same chunk" do
      a = %Cue{start_ms: 0, end_ms: 1_000, text: "a"}
      b = %Cue{start_ms: 9 * 60_000, end_ms: 9 * 60_000 + 1_000, text: "b"}

      assert [%{index: 0, cues: [^a, ^b]}] = Chunker.chunk_for_watch(%{"id" => "e"}, [a, b])
    end

    test "then chunks are returned in window order" do
      late = %Cue{start_ms: 25 * 60_000, end_ms: 25 * 60_000 + 1_000, text: "late"}
      early = %Cue{start_ms: 0, end_ms: 1_000, text: "early"}

      assert [%{index: 0}, %{index: 2}] =
               Chunker.chunk_for_watch(%{"id" => "e"}, [late, early])
    end

    test "then each chunk's index reflects its window number from zero" do
      a = %Cue{start_ms: 0, end_ms: 1_000, text: "a"}
      b = %Cue{start_ms: 10 * 60_000, end_ms: 10 * 60_000 + 1_000, text: "b"}
      c = %Cue{start_ms: 20 * 60_000, end_ms: 20 * 60_000 + 1_000, text: "c"}

      assert [%{index: 0}, %{index: 1}, %{index: 2}] =
               Chunker.chunk_for_watch(%{"id" => "e"}, [a, b, c])
    end

    test "then windows containing no cues do not appear in the output" do
      a = %Cue{start_ms: 0, end_ms: 1_000, text: "a"}
      c = %Cue{start_ms: 20 * 60_000, end_ms: 20 * 60_000 + 1_000, text: "c"}

      assert [%{index: 0}, %{index: 2}] = Chunker.chunk_for_watch(%{"id" => "e"}, [a, c])
    end

    test "then each chunk carries the source watch entry" do
      watch = %{"id" => "ep-1", "title" => "T"}
      cue = %Cue{start_ms: 0, end_ms: 1_000, text: "a"}

      assert [%{watch: ^watch}] = Chunker.chunk_for_watch(watch, [cue])
    end

    test "when given no cues then no chunks are returned" do
      assert [] = Chunker.chunk_for_watch(%{"id" => "e"}, [])
    end
  end
end
