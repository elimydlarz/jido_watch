defmodule JidoWatch.UseCase.SetupTest do
  use ExUnit.Case, async: true

  @moduletag :use_case

  alias Jido.Agent
  alias JidoWatch.Actions.SetupJidoWatch
  alias JidoWatch.Test.Support.TraktInMemory

  defp agent_with(plugin_state) do
    %Agent{
      id: "test-agent",
      agent_module: __MODULE__,
      state: %{__jido_watch__: plugin_state}
    }
  end

  defp base_plugin_state(trakt) do
    %{
      trakt: trakt,
      trakt_client_id: "client-abc",
      trakt_client_secret: "secret-xyz",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      connection: :unconnected,
      last_setup_url: nil,
      last_setup_error: nil
    }
  end

  describe "run/2 when called with no code" do
    test "then last_setup_url is set to a Trakt authorize URL carrying the client_id and redirect_uri" do
      trakt = TraktInMemory.start!()
      agent = agent_with(base_plugin_state(trakt))

      {:ok, %{__jido_watch__: new_state}} = SetupJidoWatch.run(%{}, %{agent: agent})

      assert new_state.last_setup_url =~ "https://trakt.tv/oauth/authorize?"
      assert new_state.last_setup_url =~ "client_id=client-abc"
      assert new_state.last_setup_url =~ "redirect_uri=urn"
    end

    test "then connection stays :unconnected" do
      trakt = TraktInMemory.start!()
      agent = agent_with(base_plugin_state(trakt))

      {:ok, %{__jido_watch__: new_state}} = SetupJidoWatch.run(%{}, %{agent: agent})

      assert new_state.connection == :unconnected
    end
  end

  describe "run/2 when called with a valid code" do
    test "then connection becomes {:connected, tokens} from Trakt" do
      tokens = %{access_token: "tok-1", refresh_token: "ref-1", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"good-code" => tokens})
      agent = agent_with(base_plugin_state(trakt))

      {:ok, %{__jido_watch__: new_state}} =
        SetupJidoWatch.run(%{code: "good-code"}, %{agent: agent})

      assert new_state.connection == {:connected, tokens}
    end

    test "then last_setup_error is cleared" do
      tokens = %{access_token: "tok-1", refresh_token: "ref-1", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"good-code" => tokens})

      plugin_state =
        trakt
        |> base_plugin_state()
        |> Map.put(:last_setup_error, :previous_failure)

      agent = agent_with(plugin_state)

      {:ok, %{__jido_watch__: new_state}} =
        SetupJidoWatch.run(%{code: "good-code"}, %{agent: agent})

      assert new_state.last_setup_error == nil
    end

    test "then the watermark is set to a DateTime no earlier than the moment of exchange" do
      tokens = %{access_token: "tok-1", refresh_token: "ref-1", expires_in: 7_776_000}
      trakt = TraktInMemory.start!(codes: %{"good-code" => tokens})
      agent = agent_with(base_plugin_state(trakt))

      before = DateTime.utc_now()

      {:ok, %{__jido_watch__: new_state}} =
        SetupJidoWatch.run(%{code: "good-code"}, %{agent: agent})

      assert %DateTime{} = new_state.watermark
      assert DateTime.compare(new_state.watermark, before) in [:gt, :eq]
    end
  end

  describe "run/2 if Trakt rejects the code" do
    test "then connection stays :unconnected" do
      trakt = TraktInMemory.start!(codes: %{})
      agent = agent_with(base_plugin_state(trakt))

      {:ok, %{__jido_watch__: new_state}} =
        SetupJidoWatch.run(%{code: "bad-code"}, %{agent: agent})

      assert new_state.connection == :unconnected
    end

    test "then last_setup_error is set to the reason Trakt returned" do
      trakt = TraktInMemory.start!(codes: %{})
      agent = agent_with(base_plugin_state(trakt))

      {:ok, %{__jido_watch__: new_state}} =
        SetupJidoWatch.run(%{code: "bad-code"}, %{agent: agent})

      assert new_state.last_setup_error == :invalid_code
    end
  end
end
