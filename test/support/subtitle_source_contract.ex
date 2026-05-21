defmodule JidoWatch.Test.Support.SubtitleSourceContract do
  @moduledoc """
  Shared contract suite that any `JidoWatch.Subtitle.Source` implementation must
  satisfy. The in-memory twin and the real OpenSubtitles adapter both run it.

  The consuming test module defines `setup_for/1` returning `{module, handle, entry}`
  for the requested scenario, then calls `run/0`:

      require JidoWatch.Test.Support.SubtitleSourceContract, as: SubtitleSourceContract

      defp setup_for(:fetch_available), do: ...
      defp setup_for(:fetch_unavailable), do: ...

      SubtitleSourceContract.run()

  The entry shape differs across adapters (the in-memory looks up by `"id"`; the
  HTTP adapter expects an imdb_id nested under `"movie"`/`"episode"`), so each
  setup builds the entry appropriate to its adapter.
  """

  defmacro run do
    quote do
      describe "fetch/2 when given an entry whose subtitles are available" do
        test "then returns {:ok, list_of_cues}" do
          {mod, handle, entry} = setup_for(:fetch_available)
          assert {:ok, cues} = mod.fetch(handle, entry)
          assert is_list(cues)
          refute Enum.empty?(cues)
        end
      end

      describe "fetch/2 when given an entry whose subtitles cannot be found" do
        test "then returns {:ok, :no_transcript}" do
          {mod, handle, entry} = setup_for(:fetch_unavailable)
          assert {:ok, :no_transcript} = mod.fetch(handle, entry)
        end
      end
    end
  end
end
