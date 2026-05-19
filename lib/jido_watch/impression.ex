defmodule JidoWatch.Impression do
  @moduledoc """
  Output of the agent's `experience/3` callback: an opaque-to-the-plugin reading
  of all chunk-experiences through a single angle's lens. Shape is up to the
  consuming agent.
  """

  @enforce_keys [:angle, :data]
  defstruct [:angle, :data]

  @type t :: %__MODULE__{angle: atom(), data: term()}
end
