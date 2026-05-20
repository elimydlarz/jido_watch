defmodule JidoWatch.Poller do
  @moduledoc """
  Periodic poller process owned by `JidoWatch.Plugin`. Lives for the lifetime
  of its agent — child of the AgentServer's supervised tree. Each tick reads
  the agent's plugin state; if a user is connected, a `jido_watch.poll`
  signal is cast to the agent; otherwise the tick is a no-op (no Trakt I/O,
  no callbacks). Cadence is `:poll_interval_minutes` from plugin state.
  """

  use GenServer

  alias Jido.AgentServer
  alias Jido.Signal

  @default_interval_minutes 60

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    agent_pid = Keyword.fetch!(opts, :agent_pid)
    Process.monitor(agent_pid)
    send(self(), :schedule_first)
    {:ok, %{agent_pid: agent_pid, interval_ms: nil}}
  end

  @impl GenServer
  def handle_info(:schedule_first, state) do
    interval_ms = read_interval_ms(state.agent_pid)
    Process.send_after(self(), :tick, interval_ms)
    {:noreply, %{state | interval_ms: interval_ms}}
  end

  def handle_info(:tick, state) do
    if connected?(state.agent_pid) do
      AgentServer.cast(state.agent_pid, Signal.new!(%{type: "jido_watch.poll", data: %{}}))
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, agent_pid, _reason}, %{agent_pid: agent_pid} = state) do
    {:stop, :normal, state}
  end

  defp read_interval_ms(agent_pid) do
    plugin_state = read_plugin_state(agent_pid)
    minutes = Map.get(plugin_state, :poll_interval_minutes) || @default_interval_minutes
    round(minutes * 60_000)
  end

  defp connected?(agent_pid) do
    case read_plugin_state(agent_pid).connection do
      {:connected, _} -> true
      _ -> false
    end
  end

  defp read_plugin_state(agent_pid) do
    {:ok, server_state} = AgentServer.state(agent_pid)
    server_state.agent.state[:__jido_watch__] || %{}
  end
end
