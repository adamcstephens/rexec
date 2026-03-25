defmodule Rexec do
  @moduledoc """
  Lightweight process execution with separate stdout/stderr streams.

  Provides an API compatible with erlexec's core features using a Rust
  port binary for process management.
  """

  use GenServer

  require Logger

  defstruct [:port, :ospid, :caller, :mode]

  @type signal :: :sigterm | :sigkill | :sighup | :sigint | :sigusr1 | :sigusr2 | integer()

  # Protocol tags: Rust -> Elixir
  @tag_pid 0x00
  @tag_stdout 0x01
  @tag_stderr 0x02
  @tag_exit 0x03
  @tag_signal 0x04

  # Protocol tags: Elixir -> Rust
  @cmd_stdin 0x01
  @cmd_eof 0x02
  @cmd_kill 0x03
  @cmd_kill_group 0x04

  @env_allowlist_exact MapSet.new(~w(PATH HOME USER LANG LC_ALL))
  @env_allowlist_prefixes ~w(NIX_ XDG_ LC_)

  @doc """
  Starts a process linked to the caller.

  Returns `{:ok, pid, ospid}` where `pid` is the Rexec GenServer and
  `ospid` is the OS process ID of the child.

  The caller will receive:
  - `{:stdout, ospid, data}` for stdout output
  - `{:stderr, ospid, data}` for stderr output
  - `{:EXIT, pid, reason}` when the process exits (caller must trap exits)
  """
  @spec run_link(list(), keyword()) :: {:ok, pid(), integer()} | {:error, term()}
  def run_link(cmd, opts \\ []) do
    caller = self()
    {:ok, pid} = GenServer.start_link(__MODULE__, {cmd, caller, :link, opts})

    case GenServer.call(pid, :get_ospid) do
      {:error, reason} -> {:error, reason}
      ospid when is_integer(ospid) -> {:ok, pid, ospid}
    end
  end

  @doc """
  Starts a process with monitoring.

  Returns `{:ok, pid, ospid}` where `pid` is the Rexec GenServer and
  `ospid` is the OS process ID of the child.

  The caller will receive:
  - `{:stdout, ospid, data}` for stdout output
  - `{:stderr, ospid, data}` for stderr output
  - `{:DOWN, ref, :process, pid, reason}` when the process exits
  """
  @spec run(list(), keyword()) :: {:ok, pid(), integer()} | {:error, term()}
  def run(cmd, opts \\ []) do
    caller = self()

    case GenServer.start(__MODULE__, {cmd, caller, :monitor, opts}) do
      {:ok, pid} ->
        Process.monitor(pid)

        case GenServer.call(pid, :get_ospid) do
          {:error, reason} -> {:error, reason}
          ospid when is_integer(ospid) -> {:ok, pid, ospid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends data to the stdin of the child process.
  Pass `:eof` to close stdin.
  """
  @spec send(pid(), binary() | :eof) :: :ok
  def send(pid, :eof) do
    GenServer.cast(pid, :send_eof)
  end

  def send(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:send_stdin, data})
  end

  @doc """
  Sends a signal to the child process.
  """
  @spec kill(pid(), signal()) :: :ok
  def kill(pid, signal) do
    GenServer.cast(pid, {:kill, signal_to_int(signal)})
  end

  @doc """
  Sends a signal to the child's entire process group.
  """
  @spec kill_group(pid(), signal()) :: :ok
  def kill_group(pid, signal) do
    GenServer.cast(pid, {:kill_group, signal_to_int(signal)})
  end

  # --- GenServer callbacks ---

  @impl true
  def init({cmd, caller, mode, opts}) do
    Process.flag(:trap_exit, true)

    executable = native_path()

    args =
      Enum.map(cmd, fn
        arg when is_binary(arg) -> arg
        arg when is_list(arg) -> List.to_string(arg)
        arg -> to_string(arg)
      end)

    port_opts = [
      :binary,
      :use_stdio,
      {:packet, 4},
      {:args, args}
    ]

    port_opts = add_spawn_opts(port_opts, opts)

    port =
      Port.open({:spawn_executable, executable}, port_opts)

    state = %__MODULE__{port: port, caller: caller, mode: mode}
    {:ok, state}
  end

  @impl true
  def handle_call(:get_ospid, _from, state) do
    if state.ospid do
      {:reply, state.ospid, state}
    else
      receive do
        {port, {:data, <<@tag_pid, pid::big-unsigned-32>>}} when port == state.port ->
          state = %{state | ospid: pid}
          {:reply, pid, state}
      after
        5000 ->
          {:stop, :timeout, {:error, :timeout}, state}
      end
    end
  end

  @impl true
  def handle_cast({:send_stdin, data}, state) do
    Port.command(state.port, <<@cmd_stdin, data::binary>>)
    {:noreply, state}
  end

  def handle_cast(:send_eof, state) do
    Port.command(state.port, <<@cmd_eof>>)
    {:noreply, state}
  end

  def handle_cast({:kill, signal}, %{ospid: ospid} = state) when is_integer(ospid) do
    Port.command(state.port, <<@cmd_kill, signal::big-signed-32>>)
    {:noreply, state}
  end

  def handle_cast({:kill, _signal}, state) do
    Logger.warning(msg: "Rexec: kill ignored, no managed ospid yet")
    {:noreply, state}
  end

  def handle_cast({:kill_group, signal}, %{ospid: ospid} = state) when is_integer(ospid) do
    Port.command(state.port, <<@cmd_kill_group, signal::big-signed-32>>)
    {:noreply, state}
  end

  def handle_cast({:kill_group, _signal}, state) do
    Logger.warning(msg: "Rexec: kill_group ignored, no managed ospid yet")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, <<@tag_stdout, data::binary>>}}, %{port: port} = state) do
    Kernel.send(state.caller, {:stdout, state.ospid, data})
    {:noreply, state}
  end

  def handle_info({port, {:data, <<@tag_stderr, data::binary>>}}, %{port: port} = state) do
    Kernel.send(state.caller, {:stderr, state.ospid, data})
    {:noreply, state}
  end

  def handle_info(
        {port, {:data, <<@tag_exit, code::big-signed-32>>}},
        %{port: port} = state
      ) do
    reason =
      if code == 0 do
        :normal
      else
        {:shutdown, {:exit_status, code}}
      end

    {:stop, reason, state}
  end

  def handle_info(
        {port, {:data, <<@tag_signal, signal::8>>}},
        %{port: port} = state
      ) do
    {:stop, {:shutdown, {:exit_status, 128 + signal}}, state}
  end

  def handle_info({port, {:data, <<@tag_pid, pid::big-unsigned-32>>}}, %{port: port} = state) do
    {:noreply, %{state | ospid: pid}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, reason, state}
  end

  def handle_info(msg, state) do
    Logger.warning(msg: "Rexec: unexpected message", message: inspect(msg))
    {:noreply, state}
  end

  # --- Private helpers ---

  defp add_spawn_opts(port_opts, opts) do
    port_opts
    |> add_env_opt(opts)
    |> add_cd_opt(opts)
  end

  defp add_env_opt(port_opts, opts) do
    caller_overrides = Keyword.get(opts, :env, [])
    override_map = Map.new(caller_overrides)

    current_env = System.get_env()

    # Remove all vars, then add back only allowed ones
    removals =
      for {name, _val} <- current_env,
          not env_allowed?(name),
          not Map.has_key?(override_map, name),
          do: {String.to_charlist(name), false}

    allowed =
      for {name, val} <- current_env,
          env_allowed?(name),
          not Map.has_key?(override_map, name),
          do: {String.to_charlist(name), String.to_charlist(val)}

    overrides =
      Enum.map(caller_overrides, fn
        {name, false} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    [{:env, removals ++ allowed ++ overrides} | port_opts]
  end

  defp env_allowed?(name) do
    name in @env_allowlist_exact or
      Enum.any?(@env_allowlist_prefixes, &String.starts_with?(name, &1))
  end

  defp add_cd_opt(port_opts, opts) do
    case Keyword.get(opts, :cd) do
      nil -> port_opts
      dir when is_binary(dir) -> [{:cd, String.to_charlist(dir)} | port_opts]
    end
  end

  defp native_path do
    Application.app_dir(:rexec, "priv/rexec_native")
  end

  defp signal_to_int(:sigterm), do: 15
  defp signal_to_int(:sigkill), do: 9
  defp signal_to_int(:sighup), do: 1
  defp signal_to_int(:sigint), do: 2
  defp signal_to_int(:sigusr1), do: 10
  defp signal_to_int(:sigusr2), do: 12
  defp signal_to_int(n) when is_integer(n), do: n
end
