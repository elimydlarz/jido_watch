defmodule JidoWatch.Subtitle.Source do
  @moduledoc """
  Driven port for fetching subtitle cues for a Trakt watch entry.

  Implementations are paired with an opaque handle (e.g. a base URL, or an
  in-memory twin's pid). Plugin state holds the pair as `{module, handle}`.
  """

  alias JidoWatch.Subtitle.Cue

  @type handle :: term()
  @type watch_entry :: map()

  @callback fetch(handle(), watch_entry()) ::
              {:ok, [Cue.t()]}
              | {:ok, [Cue.t()], handle()}
              | {:ok, :no_transcript}
              | {:error, term()}
end
