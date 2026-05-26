defmodule JidoWatch.Actions.UserSetup do
  @moduledoc """
  LLM-callable action that drives Trakt OAuth for the agent's user.

  - Called with no `code`: returns a Trakt authorization URL the LLM hands the user.
  - Called with `code: "..."`: exchanges the code for tokens; the user becomes connected.
  """

  use Jido.Action,
    name: "user_setup",
    description:
      "Connect this agent to the user's Trakt account. Call with no arguments to receive a URL the user visits to authorize, then call again with the resulting code.",
    schema: [
      code: [
        type: :string,
        required: false,
        doc: "Trakt authorization code returned to the user."
      ]
    ]

  alias JidoWatch.ViewingProfile

  @impl Jido.Action
  def run(params, %{agent: agent}) do
    plugin_state = Map.fetch!(agent.state, :__jido_watch__)
    run_for_params(params, plugin_state)
  end

  def run(params, %{state: %{__jido_watch__: plugin_state}}) do
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
          |> Map.put(:last_setup_profile, build_profile(module, handle, tokens.access_token))

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

  defp build_profile(module, handle, access_token) do
    with {:ok, shows} <- module.watched_shows(handle, access_token),
         {:ok, movies} <- module.watched_movies(handle, access_token),
         {:ok, recent} <- module.recent_watches(handle, access_token),
         {:ok, stats} <- module.stats(handle, access_token) do
      ViewingProfile.build(%{
        watched_shows: shows,
        watched_movies: movies,
        recent: recent,
        stats: stats
      })
    else
      _ -> nil
    end
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
