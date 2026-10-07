defmodule Rexec do
  @moduledoc """
  Linux process execution with separate stdout and stderr streams.

  The native runner requires Linux 5.3 or newer, pidfds, and a mounted,
  readable `/proc`. It acts as a child subreaper and owns the command's
  descendants, including children that escape the original process group
  with `setsid` or `setpgid`.

  Both `run/2` and `run_link/2` monitor the `:owner` option, which defaults
  to the caller. Owner death, linked caller death, and normal GenServer
  shutdown request SIGKILL for the entire owned tree. `GenServer.stop/3`
  waits for cleanup and forwards remaining output before returning.
  Killing the BEAM server with `:kill` bypasses its terminate callback;
  its death notification cannot certify cleanup, but control-channel EOF
  still asks the native runner to clean up independently.

  Successful startup returns `{:ok, pid, ospid}` only after the command
  has been spawned. Failures return `{:error, {:startup, message}}`, also
  for `run_link/2` without killing an untrapping caller.

  Output is sent to the caller as `{:stdout, ospid, data}` and
  `{:stderr, ospid, data}`. Natural completion is reported only after all
  owned descendants have been reaped and buffered output has been drained:

    * `:normal` for exit status zero
    * `{:shutdown, {:exit_status, status}}` for a nonzero exit status
    * `{:shutdown, {:signal, signal}}` for the actual terminating signal

  The direct child's outcome is preserved even when its remaining
  descendants require SIGKILL cleanup. `kill/2` targets that child,
  `kill_group/2` targets its original process group, and `kill_tree/2`
  targets the complete owned tree.

  Cleanup has a five-second deadline. If it cannot be confirmed, the
  caller receives `{:cleanup_error, ospid, message}` explicitly describing
  incomplete cleanup. The server and runner continue attempting cleanup
  while possible; eventual completion reports
  `{:shutdown, {:cleanup_failed, message}}`, never success. A terminate
  callback that cannot confirm completion within the deadline plus a
  short delivery grace fails with the same structured shutdown reason.
  An unexpected native runner exit without a completion packet is also
  a cleanup failure, not successful completion.

  The `:env` option overrides the filtered inherited environment, `:cd`
  selects the working directory, and `send/2` supplies stdin or closes it
  with `:eof`.
  """

  use GenServer

  require Logger

  defstruct [
    :port,
    :ospid,
    :caller,
    :caller_ref,
    :mode,
    :owner,
    :owner_ref,
    :outcome,
    :cleanup_error,
    ready: false,
    port_closed: false
  ]

  # Protocol tags: Rust -> Elixir
  @tag_pid 0x00
  @tag_stdout 0x01
  @tag_stderr 0x02
  @tag_exit 0x03
  @tag_signal 0x04
  @tag_startup_error 0x05
  @tag_cleanup_error 0x06

  # Protocol tags: Elixir -> Rust
  @cmd_stdin 0x01
  @cmd_eof 0x02
  @cmd_kill 0x03
  @cmd_kill_group 0x04
  @cmd_kill_tree 0x05

  @startup_timeout 5000
  @cleanup_timeout 5250

  @env_allowlist_exact MapSet.new(["PATH", "HOME", "USER", "LANG", "LC_ALL"])
  @env_allowlist_prefixes ["NIX_", "XDG_", "LC_"]

  @doc """
  Starts a process linked to the caller, monitoring `:owner` (default: caller).

  Returns `{:ok, pid, ospid}` or `{:error, {:startup, message}}`.
  Output is delivered to the caller. Completion produces
  `{:EXIT, pid, reason}`; the caller must trap exits to receive it.
  See the module documentation for exact outcomes and cleanup guarantees.
  """
  def run_link(cmd, opts \\ []) do
    start(cmd, opts, :link)
  end

  @doc """
  Starts a process with monitoring, monitoring `:owner` (default: caller).

  Returns `{:ok, pid, ospid}` or `{:error, {:startup, message}}`.
  Output is delivered to the caller. Completion produces
  `{:DOWN, ref, :process, pid, reason}`.
  See the module documentation for exact outcomes and cleanup guarantees.
  """
  def run(cmd, opts \\ []) do
    start(cmd, opts, :monitor)
  end

  @doc """
  Sends data to the stdin of the child process.
  Pass `:eof` to close stdin.
  """
  def send(pid, :eof) do
    GenServer.cast(pid, :send_eof)
  end

  def send(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:send_stdin, data})
  end

  @doc """
  Sends a signal to the child process.
  """
  def kill(pid, signal) do
    GenServer.cast(pid, {:kill, signal_to_int(signal)})
  end

  @doc """
  Sends a signal to the child's entire process group.
  """
  def kill_group(pid, signal) do
    GenServer.cast(pid, {:kill_group, signal_to_int(signal)})
  end

  @doc """
  Sends a signal to the complete owned process tree, including descendants
  outside the child's original process group.
  """
  def kill_tree(pid, signal) do
    GenServer.cast(pid, {:kill_tree, signal_to_int(signal)})
  end

  @impl GenServer
  def init({cmd, caller, startup_ref, mode, opts}) do
    Process.flag(:trap_exit, true)
    owner = Keyword.get(opts, :owner, caller)

    args =
      Enum.map(cmd, fn
        arg when is_binary(arg) -> arg
        arg when is_list(arg) -> List.to_string(arg)
        arg -> to_string(arg)
      end)

    port_opts =
      [
        :binary,
        :use_stdio,
        {:packet, 4},
        {:args, args}
      ]
      |> add_spawn_opts(opts)

    owner_ref = Process.monitor(owner)
    caller_ref = if owner != caller, do: Process.monitor(caller)

    case open_port(port_opts) do
      {:ok, port} ->
        state = %__MODULE__{
          port: port,
          caller: caller,
          owner: owner,
          owner_ref: owner_ref,
          caller_ref: caller_ref,
          mode: mode
        }

        case await_startup(state) do
          {:ok, state} ->
            Kernel.send(caller, {:rexec_started, startup_ref, self(), state.ospid})
            {:ok, state}

          {:error, message, state} ->
            close_port(state)
            {:stop, {:startup, message}}
        end

      {:error, message} ->
        {:stop, {:startup, message}}
    end
  end

  @impl GenServer
  def handle_cast(:ready, state) do
    if state.caller_ref, do: Process.demonitor(state.caller_ref, [:flush])
    state = %{state | ready: true, caller_ref: nil}

    if state.outcome,
      do: {:stop, state.outcome, state},
      else: {:noreply, state}
  end

  def handle_cast({:send_stdin, data}, state) do
    send_command(state, <<@cmd_stdin, data::binary>>)
  end

  def handle_cast(:send_eof, state) do
    send_command(state, <<@cmd_eof>>)
  end

  def handle_cast({:kill, signal}, state) do
    send_command(state, <<@cmd_kill, signal::big-signed-32>>)
  end

  def handle_cast({:kill_group, signal}, state) do
    send_command(state, <<@cmd_kill_group, signal::big-signed-32>>)
  end

  def handle_cast({:kill_tree, signal}, state) do
    send_command(state, <<@cmd_kill_tree, signal::big-signed-32>>)
  end

  @impl GenServer
  def handle_info({port, {:data, <<@tag_stdout, data::binary>>}}, %{port: port} = state) do
    Kernel.send(state.caller, {:stdout, state.ospid, data})
    {:noreply, state}
  end

  def handle_info({port, {:data, <<@tag_stderr, data::binary>>}}, %{port: port} = state) do
    Kernel.send(state.caller, {:stderr, state.ospid, data})
    {:noreply, state}
  end

  def handle_info({port, {:data, <<@tag_exit, code::big-signed-32>>}}, %{port: port} = state) do
    finish(state, exit_reason(code))
  end

  def handle_info({port, {:data, <<@tag_signal, signal::8>>}}, %{port: port} = state) do
    finish(state, {:shutdown, {:signal, signal}})
  end

  def handle_info({port, {:data, <<@tag_cleanup_error, message::binary>>}}, %{port: port} = state) do
    {:noreply, cleanup_failed(state, message)}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, %{owner_ref: ref, owner: owner} = state) do
    state = %{state | owner_ref: nil, ready: state.ready or owner == state.caller}
    send_command(state, <<@cmd_kill_tree, 9::big-signed-32>>)
  end

  def handle_info(
        {:DOWN, ref, :process, caller, _reason},
        %{caller_ref: ref, caller: caller} = state
      ) do
    state = %{state | caller_ref: nil, ready: true}

    cond do
      state.mode == :link -> send_command(state, <<@cmd_kill_tree, 9::big-signed-32>>)
      state.outcome -> {:stop, state.outcome, state}
      true -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, caller, _reason}, %{caller: caller} = state) do
    send_command(%{state | ready: true}, <<@cmd_kill_tree, 9::big-signed-32>>)
  end

  def handle_info({:EXIT, port, _reason}, %{port: port, outcome: outcome} = state)
      when not is_nil(outcome) do
    {:noreply, %{state | port_closed: true}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    state =
      cleanup_failed(
        %{state | port_closed: true},
        "native runner exited #{inspect(reason)} without confirming complete cleanup"
      )

    finish(state, {:shutdown, {:cleanup_failed, state.cleanup_error}})
  end

  def handle_info(msg, state) do
    Logger.warning(msg: "Rexec: unexpected message", message: inspect(msg))
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    case cleanup_and_wait(state) do
      {:ok, state} ->
        close_port(state)

      {:error, message, state} ->
        close_port(state)
        exit({:shutdown, {:cleanup_failed, message}})
    end
  end

  defp start(cmd, opts, mode) do
    caller = self()
    startup_ref = make_ref()
    args = {cmd, caller, startup_ref, mode, opts}

    case GenServer.start(__MODULE__, args) do
      {:ok, pid} ->
        case mode do
          :link -> Process.link(pid)
          :monitor -> Process.monitor(pid)
        end

        receive do
          {:rexec_started, ^startup_ref, ^pid, ospid} ->
            # Keep final notifications pending until the caller's link or monitor exists.
            GenServer.cast(pid, :ready)
            {:ok, pid, ospid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_port(port_opts) do
    {:ok, Port.open({:spawn_executable, native_path()}, port_opts)}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, Exception.message(error)}
  end

  defp await_startup(state) do
    receive do
      {port, {:data, <<@tag_pid, pid::big-unsigned-32>>}} when port == state.port ->
        {:ok, %{state | ospid: pid}}

      {port, {:data, <<@tag_startup_error, message::binary>>}} when port == state.port ->
        {:error, message, state}

      {:EXIT, port, reason} when port == state.port ->
        {:error, "native runner exited during startup: #{inspect(reason)}",
         %{state | port_closed: true}}

      {:DOWN, ref, :process, owner, _reason}
      when ref == state.owner_ref and owner == state.owner ->
        abort_startup(state, "owner exited during startup")

      {:DOWN, ref, :process, caller, _reason}
      when ref == state.caller_ref and caller == state.caller ->
        if state.mode == :link,
          do: abort_startup(state, "linked caller exited during startup"),
          else: await_startup(%{state | caller_ref: nil, ready: true})

      {:EXIT, caller, _reason} when caller == state.caller ->
        abort_startup(state, "linked caller exited during startup")
    after
      @startup_timeout ->
        abort_startup(state, "native runner startup timed out")
    end
  end

  defp abort_startup(state, message) do
    case cleanup_and_wait(state) do
      {:ok, state} -> {:error, message, state}
      {:error, failure, state} -> {:error, message <> "; " <> failure, state}
    end
  end

  defp send_command(%{outcome: outcome} = state, _data) when not is_nil(outcome) do
    if state.ready, do: {:stop, outcome, state}, else: {:noreply, state}
  end

  defp send_command(state, data) do
    case command(state, data) do
      :ok ->
        {:noreply, state}

      {:error, message} ->
        state = cleanup_failed(%{state | port_closed: true}, message)
        finish(state, {:shutdown, {:cleanup_failed, message}})
    end
  end

  defp command(%{port_closed: true}, _data) do
    {:error, "native runner port closed without confirming complete cleanup"}
  end

  defp command(state, data) do
    Port.command(state.port, data)
    :ok
  rescue
    ArgumentError ->
      {:error, "native runner port closed without confirming complete cleanup"}
  end

  defp finish(state, reason) do
    reason =
      if state.cleanup_error,
        do: {:shutdown, {:cleanup_failed, state.cleanup_error}},
        else: reason

    state = %{state | outcome: reason}
    if state.ready, do: {:stop, reason, state}, else: {:noreply, state}
  end

  defp cleanup_failed(state, message) do
    Kernel.send(state.caller, {:cleanup_error, state.ospid, message})
    %{state | cleanup_error: state.cleanup_error || message}
  end

  defp cleanup_and_wait(%{outcome: outcome} = state) when not is_nil(outcome) do
    if state.cleanup_error,
      do: {:error, state.cleanup_error, state},
      else: {:ok, state}
  end

  defp cleanup_and_wait(state) do
    case command(state, <<@cmd_kill_tree, 9::big-signed-32>>) do
      :ok ->
        await_cleanup(state, System.monotonic_time(:millisecond) + @cleanup_timeout)

      {:error, message} ->
        {:error, message, cleanup_failed(state, message)}
    end
  end

  defp await_cleanup(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, <<@tag_stdout, data::binary>>}} when port == state.port ->
        Kernel.send(state.caller, {:stdout, state.ospid, data})
        await_cleanup(state, deadline)

      {port, {:data, <<@tag_stderr, data::binary>>}} when port == state.port ->
        Kernel.send(state.caller, {:stderr, state.ospid, data})
        await_cleanup(state, deadline)

      {port, {:data, <<@tag_pid, pid::big-unsigned-32>>}} when port == state.port ->
        await_cleanup(%{state | ospid: pid}, deadline)

      {port, {:data, <<@tag_cleanup_error, message::binary>>}} when port == state.port ->
        await_cleanup(cleanup_failed(state, message), deadline)

      {port, {:data, <<@tag_exit, code::big-signed-32>>}} when port == state.port ->
        cleanup_and_wait(%{state | outcome: exit_reason(code)})

      {port, {:data, <<@tag_signal, signal::8>>}} when port == state.port ->
        cleanup_and_wait(%{state | outcome: {:shutdown, {:signal, signal}}})

      {port, {:data, <<@tag_startup_error, _message::binary>>}} when port == state.port ->
        {:ok, state}

      {:EXIT, port, reason} when port == state.port ->
        message = "native runner exited #{inspect(reason)} without confirming complete cleanup"
        {:error, message, cleanup_failed(%{state | port_closed: true}, message)}
    after
      remaining ->
        message =
          state.cleanup_error ||
            "cleanup deadline exceeded; complete process-tree cleanup has not been confirmed"

        state = if state.cleanup_error, do: state, else: cleanup_failed(state, message)
        {:error, message, state}
    end
  end

  defp close_port(%{port_closed: true}), do: :ok

  defp close_port(state) do
    Port.close(state.port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp exit_reason(0), do: :normal
  defp exit_reason(code), do: {:shutdown, {:exit_status, code}}

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
