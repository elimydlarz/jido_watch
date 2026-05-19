defmodule JidoWatch do
  @moduledoc """
  Behaviour the consuming agent implements to participate in the watching
  pipeline.

  The plugin calls these in order: `watch/2` once per chunk in sequence,
  `experience/3` once per configured angle in parallel, then `form_opinion/2`
  once with the collected impressions. Inference (LLM, memory) lives inside
  these callbacks; the plugin never sees prompts, models, or the delivery
  channel.

  Each callback receives the agent struct as its first argument so the host
  can read its own state (LLM client, memory backend, voice configuration)
  without resolving its server pid.

  See `VISION.md`, `CLAUDE.md`, and `TEST_TREES.md` for the full framing.
  """

  alias Jido.Agent
  alias JidoWatch.Chunk
  alias JidoWatch.Experience
  alias JidoWatch.Impression

  @callback watch(Agent.t(), Chunk.t()) :: {:ok, Experience.t()} | {:error, term()}

  @callback experience(Agent.t(), [Experience.t()], angle :: atom()) ::
              {:ok, Impression.t()} | {:error, term()}

  @callback form_opinion(Agent.t(), [Impression.t()]) :: :ok | {:error, term()}
end
