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

  describe "run/2 when the connection is {:connected, tokens} and the pipeline succeeds" do
    test "then the new watermark and pending_watches are written to plugin state" do
      alias JidoWatch.Subtitle.Cue

      tokens = %{access_token: "tok", refresh_token: "ref", expires_in: 7_776_000}

      entry = %{
        "id" => "ep-1",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      trakt = TraktInMemory.start!(watches: [entry])

      subtitles =
        SubtitleInMemory.start!(
          cues: %{"ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}]}
        )

      agent =
        agent_with(
          base_plugin_state(trakt, subtitles, %{connection: {:connected, tokens}})
        )

      assert {:ok, %{__jido_watch__: new_state}} = PollWatches.run(%{}, %{agent: agent})

      assert new_state.watermark == ~U[2025-07-01 00:00:00Z]
      assert new_state.pending_watches == []
    end
  end

  describe "run/2 when the connection is {:connected, tokens} and the pipeline returns :unauthorized and the refresh succeeds" do
    setup do
      alias JidoWatch.Subtitle.Cue

      old_tokens = %{access_token: "old-tok", refresh_token: "old-ref", expires_in: 7_776_000}
      new_tokens = %{access_token: "new-tok", refresh_token: "new-ref", expires_in: 7_776_000}

      entry = %{
        "id" => "ep-1",
        "type" => "movie",
        "watched_at" => "2025-07-01T00:00:00Z",
        "movie" => %{"ids" => %{"imdb" => "tt0"}}
      }

      trakt =
        TraktInMemory.start!(
          watches: [entry],
          unauthorized_access_tokens: ["old-tok"],
          refresh_chain: %{"old-ref" => new_tokens}
        )

      subtitles =
        SubtitleInMemory.start!(
          cues: %{"ep-1" => [%Cue{start_ms: 0, end_ms: 1_000, text: "x"}]}
        )

      agent =
        agent_with(
          base_plugin_state(trakt, subtitles, %{connection: {:connected, old_tokens}})
        )

      %{agent: agent, trakt: trakt, new_tokens: new_tokens}
    end

    test "then the new access_token and refresh_token replace the stored pair", %{
      agent: agent,
      new_tokens: new_tokens
    } do
      assert {:ok, %{__jido_watch__: new_state}} = PollWatches.run(%{}, %{agent: agent})

      assert new_state.connection == {:connected, new_tokens}
    end

    test "then the pipeline is replayed with the new access_token", %{
      agent: agent,
      trakt: trakt
    } do
      assert {:ok, _} = PollWatches.run(%{}, %{agent: agent})

      assert TraktInMemory.recent_watches_calls(trakt) == 2
      assert_received {:form_opinion_called, _}
    end

    test "then the new watermark and pending_watches are written to plugin state", %{
      agent: agent
    } do
      assert {:ok, %{__jido_watch__: new_state}} = PollWatches.run(%{}, %{agent: agent})

      assert new_state.watermark == ~U[2025-07-01 00:00:00Z]
      assert new_state.pending_watches == []
    end
  end

  describe "run/2 when the connection is {:connected, tokens} and the pipeline returns :unauthorized and the refresh returns :invalid_grant" do
    test "then the connection flips to :unconnected" do
      old_tokens = %{access_token: "old-tok", refresh_token: "dead-ref", expires_in: 7_776_000}

      trakt =
        TraktInMemory.start!(
          unauthorized_access_tokens: ["old-tok"],
          refresh_chain: %{}
        )

      subtitles = SubtitleInMemory.start!()

      agent =
        agent_with(
          base_plugin_state(trakt, subtitles, %{connection: {:connected, old_tokens}})
        )

      assert {:ok, %{__jido_watch__: new_state}} = PollWatches.run(%{}, %{agent: agent})

      assert new_state.connection == :unconnected
    end
  end
end
