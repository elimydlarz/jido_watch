defmodule JidoWatch.Test.Support.RecordingHost do
  @moduledoc """
  `@behaviour JidoWatch` fixture for use-case tests.

  Each callback sends a tagged tuple to the `test_pid` stashed in
  `agent.state` and returns canned data so the pipeline can keep flowing.
  """

  @behaviour JidoWatch

  alias JidoWatch.Experience
  alias JidoWatch.Impression

  @impl JidoWatch
  def watch(agent, chunk) do
    send(agent.state.test_pid, {:watch_called, chunk})
    {:ok, %Experience{chunk: chunk, data: chunk.index}}
  end

  @impl JidoWatch
  def experience(agent, experiences, angle) do
    send(agent.state.test_pid, {:experience_called, angle, experiences})
    {:ok, %Impression{angle: angle, data: length(experiences)}}
  end

  @impl JidoWatch
  def form_opinion(agent, impressions) do
    send(agent.state.test_pid, {:form_opinion_called, impressions})
    :ok
  end
end
