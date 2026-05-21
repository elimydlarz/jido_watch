defmodule JidoWatch.Adapter.SubtitleInMemoryTest do
  use ExUnit.Case, async: true

  @moduletag :adapter

  alias JidoWatch.Subtitle.Cue
  alias JidoWatch.Test.Support.SubtitleInMemory

  require JidoWatch.Test.Support.SubtitleSourceContract
  alias JidoWatch.Test.Support.SubtitleSourceContract

  defp setup_for(:fetch_available) do
    entry = %{"id" => "ep-1"}
    handle = SubtitleInMemory.start!(cues: %{"ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "a"}]})
    {SubtitleInMemory, elem(handle, 1), entry}
  end

  defp setup_for(:fetch_unavailable) do
    entry = %{"id" => "ep-missing"}
    handle = SubtitleInMemory.start!(cues: %{})
    {SubtitleInMemory, elem(handle, 1), entry}
  end

  SubtitleSourceContract.run()
end
