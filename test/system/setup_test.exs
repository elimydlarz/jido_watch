defmodule JidoWatch.System.SetupTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias JidoWatch.Test.Support.HostAgent
  alias JidoWatch.Test.Support.TraktInMemory

  describe "when the agent calls the setup_jido_watch action for an unconnected user" do
    test "then an authorization URL is returned" do
      trakt = TraktInMemory.start!()

      {:ok, pid} =
        HostAgent.start_link(trakt: trakt, trakt_client_id: "client-abc")

      assert {:ok, url} = HostAgent.setup_jido_watch(pid)
      assert is_binary(url)
      assert url =~ "trakt.tv"
      assert url =~ "client_id=client-abc"
    end
  end

  describe "when called with a valid auth code for that user" do
    test "then the user becomes connected" do
      tokens = %{access_token: "tok-abc", refresh_token: "ref-abc", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"good-code" => tokens})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      refute HostAgent.connected?(pid)

      assert :ok = HostAgent.complete_setup(pid, "good-code")
      assert HostAgent.connected?(pid)
    end
  end

  describe "when called with an invalid code" do
    test "then the user does not become connected" do
      trakt = TraktInMemory.start!(codes: %{})

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      assert {:error, _reason} = HostAgent.complete_setup(pid, "bad-code")
      refute HostAgent.connected?(pid)
    end
  end

  describe "when a user is not connected" do
    test "then no watching happens for them" do
      trakt = TraktInMemory.start!()

      {:ok, pid} =
        HostAgent.start_link(
          trakt: trakt,
          trakt_client_id: "client-abc",
          trakt_client_secret: "secret-abc"
        )

      refute HostAgent.connected?(pid)

      :ok = HostAgent.poll(pid)

      assert TraktInMemory.recent_watches_calls(trakt) == 0
    end
  end
end
