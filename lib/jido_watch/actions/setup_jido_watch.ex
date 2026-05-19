defmodule JidoWatch.Actions.SetupJidoWatch do
  @moduledoc """
  LLM-callable action that drives Trakt OAuth for the agent's user.

  - Called with no `code`: returns a Trakt authorization URL the LLM hands the user.
  - Called with `code: "..."`: exchanges the code for tokens; the user becomes connected.
  """

  use Jido.Action,
    name: "setup_jido_watch",
    description:
      "Connect this agent to the user's Trakt account. Call with no arguments to receive a URL the user visits to authorize, then call again with the resulting code.",
    schema: [
      code: [type: :string, required: false, doc: "Trakt authorization code returned to the user."]
    ]

  @impl Jido.Action
  def run(params, %{agent: agent}) do
    plugin_state = Map.fetch!(agent.state, :__jido_watch__)
    run_for_params(params, plugin_state)
  end

  defp run_for_params(%{code: code}, plugin_state) when is_binary(code) do
    {module, handle} = plugin_state.trakt

    case module.exchange_code(handle, code) do
      {:ok, tokens} ->
        new_state =
          plugin_state
          |> Map.put(:connection, {:connected, tokens})
          |> Map.put(:watermark, DateTime.utc_now())
          |> Map.put(:last_setup_error, nil)

        {:ok, %{__jido_watch__: new_state}}

      {:error, reason} ->
        new_state = Map.put(plugin_state, :last_setup_error, reason)
        {:ok, %{__jido_watch__: new_state}}
    end
  end

  defp run_for_params(_params, plugin_state) do
    url = authorization_url(plugin_state)
    {:ok, %{__jido_watch__: Map.put(plugin_state, :last_setup_url, url)}}
  end

  defp authorization_url(%{trakt_client_id: client_id, redirect_uri: redirect_uri}) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    "https://trakt.tv/oauth/authorize?" <> query
  end
end
