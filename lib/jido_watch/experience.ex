defmodule JidoWatch.Experience do
  @moduledoc """
  Output of the agent's `watch/2` callback: an opaque-to-the-plugin reading of
  one chunk. Shape is up to the consuming agent.
  """

  @enforce_keys [:chunk, :data]
  defstruct [:chunk, :data]

  @type t :: %__MODULE__{chunk: JidoWatch.Chunk.t(), data: term()}
end
