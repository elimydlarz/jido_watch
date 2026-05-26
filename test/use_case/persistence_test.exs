defmodule JidoWatch.UseCase.PersistenceTest do
  use ExUnit.Case, async: false

  @moduletag :use_case

  alias Jido.Persist
  alias Jido.Storage.ETS, as: EtsStorage
  alias JidoWatch.Test.Support.PersistenceHostAgent
  alias JidoWatch.Test.Support.TraktInMemory
  alias JidoWatch.Test.Support.SubtitleInMemory

  @table :jido_watch_persistence_test_storage

  setup do
    :ok = EtsStorage.delete_checkpoint(checkpoint_key(), table: @table)
    :ok
  end

  describe "when an agent is hibernated and thawed" do
    test "then connection survives unchanged" do
      tokens = %{access_token: "at-1", refresh_token: "rt-1", expires_in: 7200}
      agent = build_agent(%{connection: {:connected, tokens}})

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      assert restored.state[:__jido_watch__].connection == {:connected, tokens}
    end

    test "then watermark survives unchanged" do
      watermark = ~U[2026-05-21 09:14:32Z]
      agent = build_agent(%{watermark: watermark})

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      assert restored.state[:__jido_watch__].watermark == watermark
    end

    test "then pending_watches survives unchanged with entries in original order" do
      entries = [
        %{"id" => 11, "watched_at" => "2026-05-19T20:00:00Z"},
        %{"id" => 7, "watched_at" => "2026-05-20T22:30:00Z"},
        %{"id" => 23, "watched_at" => "2026-05-21T09:00:00Z"}
      ]

      agent = build_agent(%{pending_watches: entries})

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      assert restored.state[:__jido_watch__].pending_watches == entries
    end

    test "then trakt and subtitles are taken from plugin config, not the checkpoint" do
      agent =
        build_agent(%{
          trakt: {TraktInMemory, :stale_handle},
          subtitles: {SubtitleInMemory, :stale_handle}
        })

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      assert restored.state[:__jido_watch__].trakt == PersistenceHostAgent.trakt_from_config()

      assert restored.state[:__jido_watch__].subtitles ==
               PersistenceHostAgent.subtitles_from_config()
    end

    test "then trakt_client_id, trakt_client_secret, and redirect_uri are taken from plugin config" do
      agent =
        build_agent(%{
          trakt_client_id: "stale-id",
          trakt_client_secret: "stale-secret",
          redirect_uri: "stale://redirect"
        })

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      slice = restored.state[:__jido_watch__]
      assert slice.trakt_client_id == PersistenceHostAgent.trakt_client_id()
      assert slice.trakt_client_secret == PersistenceHostAgent.trakt_client_secret()
      assert slice.redirect_uri == PersistenceHostAgent.redirect_uri()
    end

    test "then angles and poll_interval_minutes are taken from plugin config" do
      agent =
        build_agent(%{
          angles: [:stale_angle_one, :stale_angle_two],
          poll_interval_minutes: 999
        })

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      slice = restored.state[:__jido_watch__]
      assert slice.angles == PersistenceHostAgent.angles()
      assert slice.poll_interval_minutes == PersistenceHostAgent.poll_interval_minutes()
    end

    test "then last_setup_url, last_setup_error, and last_setup_profile are nil" do
      agent =
        build_agent(%{
          last_setup_url: "https://trakt.tv/oauth/authorize?...",
          last_setup_error: :previous_failure,
          last_setup_profile: %JidoWatch.ViewingProfile{
            shows_watched: 1,
            movies_watched: 0,
            episodes_watched: 0,
            genre_distribution: %{},
            most_watched_shows: [],
            recently_watched: [],
            ratings_distribution: %{}
          }
        })

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      slice = restored.state[:__jido_watch__]
      assert slice.last_setup_url == nil
      assert slice.last_setup_error == nil
      assert slice.last_setup_profile == nil
    end

    test "when the agent was unconnected before hibernation then connection is :unconnected, watermark is nil, pending_watches is empty" do
      agent =
        build_agent(%{
          connection: :unconnected,
          watermark: nil,
          pending_watches: []
        })

      :ok = hibernate(agent)
      {:ok, restored} = thaw()

      slice = restored.state[:__jido_watch__]
      assert slice.connection == :unconnected
      assert slice.watermark == nil
      assert slice.pending_watches == []
    end
  end

  defp build_agent(slice_overrides) do
    agent = PersistenceHostAgent.new(id: "persistence-test-agent")
    existing = agent.state[:__jido_watch__]
    %{agent | state: Map.put(agent.state, :__jido_watch__, Map.merge(existing, slice_overrides))}
  end

  defp hibernate(agent) do
    Persist.hibernate(
      {EtsStorage, [table: @table]},
      PersistenceHostAgent,
      checkpoint_id(),
      agent
    )
  end

  defp thaw do
    Persist.thaw({EtsStorage, [table: @table]}, PersistenceHostAgent, checkpoint_id())
  end

  defp checkpoint_id, do: "persistence-test-agent"

  defp checkpoint_key, do: {PersistenceHostAgent, checkpoint_id()}
end
