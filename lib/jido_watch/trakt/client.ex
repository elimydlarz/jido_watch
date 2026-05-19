defmodule JidoWatch.Trakt.Client do
  @moduledoc """
  Driven port for Trakt operations the plugin needs.

  Implementations are paired with an opaque handle (e.g. an HTTP base URL and
  credentials, or an in-memory twin's pid). Plugin state holds the pair as
  `{module, handle}`.
  """

  @type handle :: term()

  @type tokens :: %{
          access_token: binary(),
          refresh_token: binary(),
          expires_in: pos_integer()
        }

  @callback exchange_code(handle(), code :: binary()) ::
              {:ok, tokens()} | {:error, term()}

  @callback recent_watches(handle(), access_token :: binary()) ::
              {:ok, [map()]} | {:error, term()}
end
