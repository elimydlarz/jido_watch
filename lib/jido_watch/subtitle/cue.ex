defmodule JidoWatch.Subtitle.Cue do
  @enforce_keys [:start_ms, :end_ms, :text]
  defstruct [:start_ms, :end_ms, :text]

  @type t :: %__MODULE__{
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer(),
          text: binary()
        }
end
