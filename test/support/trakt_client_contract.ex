defmodule JidoWatch.Test.Support.TraktClientContract do
  @moduledoc """
  Shared contract suite that any `JidoWatch.Trakt.Client` implementation must
  satisfy. The in-memory twin and the real HTTP adapter both run it.

  The consuming test module defines `setup_for/1` returning a `{module, handle}`
  configured for the requested scenario, then calls `run/0`:

      require JidoWatch.Test.Support.TraktClientContract, as: TraktClientContract

      defp setup_for(:exchange_code_valid), do: ...
      defp setup_for(:exchange_code_invalid), do: ...
      defp setup_for(:refresh_valid), do: ...
      defp setup_for(:refresh_invalid_grant), do: ...
      defp setup_for(:recent_watches_valid), do: ...
      defp setup_for(:recent_watches_unauthorized), do: ...

      TraktClientContract.run()

  Scenarios use the canonical inputs the contract tests will pass:
    - `exchange_code(handle, "code-good")` for `:exchange_code_valid`
    - `exchange_code(handle, "code-bad")` for `:exchange_code_invalid`
    - `exchange_refresh_token(handle, "ref-good")` for `:refresh_valid`
    - `exchange_refresh_token(handle, "ref-dead")` for `:refresh_invalid_grant`
    - `recent_watches(handle, "tok-good")` for `:recent_watches_valid`
    - `recent_watches(handle, "tok-dead")` for `:recent_watches_unauthorized`
  """

  defmacro run do
    quote do
      describe "exchange_code/2 when given a code the server accepts" do
        test "then returns {:ok, %{access_token, refresh_token, expires_in}}" do
          {mod, handle} = setup_for(:exchange_code_valid)
          assert {:ok, tokens} = mod.exchange_code(handle, "code-good")
          assert is_binary(tokens.access_token)
          assert is_binary(tokens.refresh_token)
          assert is_integer(tokens.expires_in)
        end
      end

      describe "exchange_code/2 when given a code the server rejects" do
        test "then returns an error" do
          {mod, handle} = setup_for(:exchange_code_invalid)
          assert {:error, _} = mod.exchange_code(handle, "code-bad")
        end
      end

      describe "exchange_refresh_token/2 when given a refresh token the server accepts" do
        test "then returns {:ok, %{access_token, refresh_token, expires_in}}" do
          {mod, handle} = setup_for(:refresh_valid)
          assert {:ok, tokens} = mod.exchange_refresh_token(handle, "ref-good")
          assert is_binary(tokens.access_token)
          assert is_binary(tokens.refresh_token)
          assert is_integer(tokens.expires_in)
        end
      end

      describe "exchange_refresh_token/2 when the refresh token is expired, revoked, or otherwise invalid" do
        test "then returns {:error, :invalid_grant}" do
          {mod, handle} = setup_for(:refresh_invalid_grant)
          assert {:error, :invalid_grant} = mod.exchange_refresh_token(handle, "ref-dead")
        end
      end

      describe "recent_watches/2 when the access token is accepted" do
        test "then returns {:ok, list_of_entries}" do
          {mod, handle} = setup_for(:recent_watches_valid)
          assert {:ok, entries} = mod.recent_watches(handle, "tok-good")
          assert is_list(entries)
        end
      end

      describe "recent_watches/2 when the access token is rejected by the server" do
        test "then returns {:error, :unauthorized}" do
          {mod, handle} = setup_for(:recent_watches_unauthorized)
          assert {:error, :unauthorized} = mod.recent_watches(handle, "tok-dead")
        end
      end
    end
  end
end
