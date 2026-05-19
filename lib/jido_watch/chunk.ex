defmodule JidoWatch.Chunk do
  @moduledoc """
  One 10-minute attention window of subtitle cues from a single watch entry.
  """

  alias JidoWatch.Subtitle.Cue

  @enforce_keys [:watch, :index, :start_ms, :end_ms, :cues]
  defstruct [:watch, :index, :start_ms, :end_ms, :cues]

  @type t :: %__MODULE__{
          watch: map(),
          index: non_neg_integer(),
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer(),
          cues: [Cue.t()]
        }
end
