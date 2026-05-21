defmodule JidoWatch.UseCase.PollWatchesTest do
  use ExUnit.Case, async: true

  @moduletag :use_case

  alias Jido.Agent
  alias JidoWatch.Actions.PollWatches
  alias JidoWatch.Test.Support.RecordingHost
  alias JidoWatch.Test.Support.SubtitleInMemory
  alias JidoWatch.Test.Support.TraktInMemory

  defp agent_with(plugin_state) do
    %Agent{
      id: "test-agent",
      agent_module: RecordingHost,
      state: %{__jido_watch__: plugin_state, test_pid: self()}
    }
  end

  defp base_plugin_state(trakt, subtitles, overrides \\ %{}) do
    Map.merge(
      %{
        trakt: trakt,
        subtitles: subtitles,
        trakt_client_id: "client-abc",
        trakt_client_secret: "secret-xyz",
        angles: [:theme],
        connection: :unconnected,
        watermark: nil,
        pending_watches: []
      },
      overrides
    )
  end

  describe "run/2 when the connection is :unconnected" do
    test "then no Trakt I/O happens and plugin state is not changed" do
      trakt = TraktInMemory.start!()
      subtitles = SubtitleInMemory.start!()
      agent = agent_with(base_plugin_state(trakt, subtitles))

      assert {:ok, %{}} = PollWatches.run(%{}, %{agent: agent})

      assert TraktInMemory.recent_watches_calls(trakt) == 0
    end
  end
end
