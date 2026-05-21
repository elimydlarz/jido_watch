defmodule JidoWatch.Test.Support.HostAgent do
  @moduledoc """
  Fixture host agent used by the system tests.

  A real `Jido.Agent` that mounts the real `JidoWatch.Plugin` and implements
  the `JidoWatch` behaviour with canned callback bodies that forward every
  invocation to a configurable `test_pid` so tests can assert on the order
  and arguments of plugin-to-agent calls.
  """

  use Jido.Agent,
    name: "jido_watch_test_host_agent",
    plugins: [JidoWatch.Plugin]

  @behaviour JidoWatch

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoWatch.Experience
  alias JidoWatch.Impression

  def start_link(opts) do
    trakt = Keyword.fetch!(opts, :trakt)
    client_id = Keyword.fetch!(opts, :trakt_client_id)
    client_secret = Keyword.get(opts, :trakt_client_secret)
    subtitles = Keyword.get(opts, :subtitles)
    test_pid = Keyword.get(opts, :test_pid)
    angles = Keyword.get(opts, :angles, [:theme])
    connection = Keyword.get(opts, :connection, :unconnected)
    watermark = Keyword.get(opts, :watermark)
    poll_interval_minutes = Keyword.get(opts, :poll_interval_minutes)
    transient_retry_delay_ms = Keyword.get(opts, :transient_retry_delay_ms)

    plugin_state =
      %{
        trakt: trakt,
        subtitles: subtitles,
        trakt_client_id: client_id,
        trakt_client_secret: client_secret,
        angles: angles,
        connection: connection,
        watermark: watermark
      }
      |> maybe_put(:poll_interval_minutes, poll_interval_minutes)
      |> maybe_put(:transient_retry_delay_ms, transient_retry_delay_ms)

    AgentServer.start_link(
      agent: __MODULE__,
      register_global: false,
      initial_state: %{
        __jido_watch__: plugin_state,
        test_pid: test_pid
      }
    )
  end

  def user_setup(pid) do
    case call_user_setup(pid, %{}) do
      {:ok, agent} -> {:ok, agent.state[:__jido_watch__].last_setup_url}
      other -> other
    end
  end

  def complete_user_setup(pid, code) do
    case call_user_setup(pid, %{code: code}) do
      {:ok, agent} ->
        case agent.state[:__jido_watch__].last_setup_error do
          nil -> :ok
          reason -> {:error, reason}
        end

      other ->
        other
    end
  end

  def connected?(pid) do
    {:ok, state} = AgentServer.state(pid)
    match?({:connected, _}, state.agent.state[:__jido_watch__].connection)
  end

  def access_token(pid) do
    {:ok, state} = AgentServer.state(pid)

    case state.agent.state[:__jido_watch__].connection do
      {:connected, %{access_token: token}} -> {:ok, token}
      _ -> {:error, :not_connected}
    end
  end

  def tokens(pid) do
    {:ok, state} = AgentServer.state(pid)

    case state.agent.state[:__jido_watch__].connection do
      {:connected, tokens} -> {:ok, tokens}
      _ -> {:error, :not_connected}
    end
  end

  def watermark(pid) do
    {:ok, state} = AgentServer.state(pid)
    state.agent.state[:__jido_watch__].watermark
  end

  def poll(pid) do
    signal = Signal.new!(%{type: "jido_watch.poll", data: %{}})

    case AgentServer.call(pid, signal) do
      {:ok, _agent} -> :ok
      other -> other
    end
  end

  @impl JidoWatch
  def watch(agent, chunk) do
    notify(agent, {:watch_called, chunk})
    {:ok, %Experience{chunk: chunk, data: {:watched, chunk.index}}}
  end

  @impl JidoWatch
  def experience(agent, experiences, angle) do
    notify(agent, {:experience_called, angle, experiences})
    {:ok, %Impression{angle: angle, data: {:impressed, length(experiences)}}}
  end

  @impl JidoWatch
  def form_opinion(agent, impressions) do
    notify(agent, {:form_opinion_called, impressions})
    :ok
  end

  defp notify(agent, message) do
    case agent.state[:test_pid] do
      nil -> :ok
      test_pid -> send(test_pid, message)
    end
  end

  defp call_user_setup(pid, data) do
    signal = Signal.new!(%{type: "jido_watch.user_setup", data: data})
    AgentServer.call(pid, signal)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
