defmodule JidoWatch.Test.Support.PersistenceHostAgent do
  @moduledoc """
  Fixture host agent for `JidoWatch.UseCase.PersistenceTest`.

  Mounts `JidoWatch.Plugin` with a fixed, compile-time plugin config so the
  tests can hibernate and thaw real agents through `Jido.Persist` and assert
  that non-durable fields come from this config rather than the checkpoint.
  """

  @trakt_from_config {__MODULE__.FreshTraktClient, :fresh_handle}
  @subtitles_from_config {__MODULE__.FreshSubtitleSource, :fresh_handle}
  @trakt_client_id "config-client-id"
  @trakt_client_secret "config-client-secret"
  @redirect_uri "https://example.test/oauth/callback"
  @angles [:emerging_themes, :character_readings, :cross_show_rhymes, :loose_threads]
  @poll_interval_minutes 13

  use Jido.Agent,
    name: "jido_watch_persistence_host",
    plugins: [
      {JidoWatch.Plugin,
       %{
         trakt: @trakt_from_config,
         subtitles: @subtitles_from_config,
         trakt_client_id: @trakt_client_id,
         trakt_client_secret: @trakt_client_secret,
         redirect_uri: @redirect_uri,
         angles: @angles,
         poll_interval_minutes: @poll_interval_minutes
       }}
    ]

  @behaviour JidoWatch

  alias JidoWatch.Experience
  alias JidoWatch.Impression

  def trakt_from_config, do: @trakt_from_config
  def subtitles_from_config, do: @subtitles_from_config
  def trakt_client_id, do: @trakt_client_id
  def trakt_client_secret, do: @trakt_client_secret
  def redirect_uri, do: @redirect_uri
  def angles, do: @angles
  def poll_interval_minutes, do: @poll_interval_minutes

  @impl JidoWatch
  def watch(_agent, chunk), do: {:ok, %Experience{chunk: chunk, data: nil}}

  @impl JidoWatch
  def experience(_agent, _experiences, angle), do: {:ok, %Impression{angle: angle, data: nil}}

  @impl JidoWatch
  def form_opinion(_agent, _impressions), do: :ok
end
