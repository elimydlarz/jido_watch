defmodule JidoWatch.Adapter.TraktInMemoryTest do
  use ExUnit.Case, async: true

  @moduletag :adapter

  alias JidoWatch.Test.Support.TraktInMemory

  require JidoWatch.Test.Support.TraktClientContract
  alias JidoWatch.Test.Support.TraktClientContract

  @tokens %{access_token: "tok-fresh", refresh_token: "ref-fresh", expires_in: 7_776_000}

  defp setup_for(:exchange_code_valid), do: TraktInMemory.start!(codes: %{"code-good" => @tokens})
  defp setup_for(:exchange_code_invalid), do: TraktInMemory.start!(codes: %{})
  defp setup_for(:refresh_valid), do: TraktInMemory.start!(refresh_chain: %{"ref-good" => @tokens})
  defp setup_for(:refresh_invalid_grant), do: TraktInMemory.start!(refresh_chain: %{})
  defp setup_for(:recent_watches_valid), do: TraktInMemory.start!(watches: [%{"id" => "ep-1"}])

  defp setup_for(:recent_watches_unauthorized),
    do: TraktInMemory.start!(unauthorized_access_tokens: ["tok-dead"])

  defp setup_for(:watched_shows_valid), do: TraktInMemory.start!(watched_shows: [%{"plays" => 1}])

  defp setup_for(:watched_shows_unauthorized),
    do: TraktInMemory.start!(unauthorized_access_tokens: ["tok-dead"])

  defp setup_for(:watched_movies_valid), do: TraktInMemory.start!(watched_movies: [%{"plays" => 1}])

  defp setup_for(:watched_movies_unauthorized),
    do: TraktInMemory.start!(unauthorized_access_tokens: ["tok-dead"])

  defp setup_for(:stats_valid), do: TraktInMemory.start!(stats: %{"episodes" => %{"watched" => 1}})

  defp setup_for(:stats_unauthorized),
    do: TraktInMemory.start!(unauthorized_access_tokens: ["tok-dead"])

  TraktClientContract.run()
end
