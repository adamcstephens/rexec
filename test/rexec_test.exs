defmodule RexecTest do
  use ExUnit.Case, async: true

  describe "run_link/2" do
    test "runs a command and returns pid and ospid" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["echo", "hello"])

      assert is_pid(pid)
      assert is_integer(ospid)
      assert ospid > 0

      assert_receive {:stdout, ^ospid, "hello\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "captures stderr output" do
      Process.flag(:trap_exit, true)
      cmd = ["sh", "-c", "echo err >&2"]
      {:ok, pid, ospid} = Rexec.run_link(cmd)

      assert_receive {:stderr, ^ospid, "err\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "reports non-zero exit status" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "exit 42"])

      assert_receive {:EXIT, ^pid, {:shutdown, {:exit_status, 42}}}, 5000
      assert is_integer(ospid)
    end

    test "handles multi-line stdout" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "echo line1; echo line2"])

      stdout = collect_stdout(ospid, pid)
      assert stdout =~ "line1"
      assert stdout =~ "line2"
    end

    test "handles both stdout and stderr" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "echo out; echo err >&2"])

      {stdout, stderr} = collect_output(ospid, pid)
      assert stdout =~ "out"
      assert stderr =~ "err"
    end

    test "passes environment variables to child" do
      Process.flag(:trap_exit, true)

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo $REXEC_TEST_VAR"],
          env: [{"REXEC_TEST_VAR", "hello_from_env"}]
        )

      assert_receive {:stdout, ^ospid, "hello_from_env\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "runs command in specified working directory" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["pwd"], cd: "/tmp")

      assert_receive {:stdout, ^ospid, "/tmp\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "excludes non-allowlisted env vars from child" do
      Process.flag(:trap_exit, true)
      # Set a var in the BEAM that should NOT pass through
      System.put_env("REXEC_SHOULD_BE_HIDDEN", "secret")

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo ${REXEC_SHOULD_BE_HIDDEN:-hidden}"])

      assert_receive {:stdout, ^ospid, "hidden\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    after
      System.delete_env("REXEC_SHOULD_BE_HIDDEN")
    end

    test "passes allowlisted env vars to child" do
      Process.flag(:trap_exit, true)

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo $PATH"])

      path = System.fetch_env!("PATH") <> "\n"
      assert_receive {:stdout, ^ospid, ^path}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "passes NIX_ prefixed vars to child" do
      Process.flag(:trap_exit, true)
      System.put_env("NIX_TEST_PASSTHROUGH", "nix_value")

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo $NIX_TEST_PASSTHROUGH"])

      assert_receive {:stdout, ^ospid, "nix_value\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    after
      System.delete_env("NIX_TEST_PASSTHROUGH")
    end

    test "per-call env overrides allowlist defaults" do
      Process.flag(:trap_exit, true)

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo ${HOME:-unset}"], env: [{"HOME", false}])

      assert_receive {:stdout, ^ospid, "unset\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end
  end

  describe "run/2" do
    test "runs a command with monitoring" do
      {:ok, pid, ospid} = Rexec.run(["echo", "hello"])

      assert is_pid(pid)
      assert is_integer(ospid)

      assert_receive {:stdout, ^ospid, "hello\n"}, 5000
      assert_receive {:DOWN, _ref, :process, ^pid, :normal}, 5000
    end

    test "reports non-zero exit via DOWN message" do
      {:ok, pid, ospid} = Rexec.run(["sh", "-c", "exit 7"])

      assert is_integer(ospid)
      assert_receive {:DOWN, _ref, :process, ^pid, {:shutdown, {:exit_status, 7}}}, 5000
    end
  end

  describe "send/2" do
    test "sends data to stdin" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["cat"])

      :ok = Rexec.send(pid, "hello world")
      :ok = Rexec.send(pid, :eof)

      assert_receive {:stdout, ^ospid, "hello world"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end
  end

  describe "kill/2" do
    test "sends signal to terminate process" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sleep", "60"])

      assert is_integer(ospid)

      Rexec.kill(pid, :sigterm)
      assert_receive {:EXIT, ^pid, {:shutdown, {:signal, 15}}}, 5000
    end

    test "accepts integer signals" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sleep", "60"])

      assert is_integer(ospid)

      # SIGTERM = 15
      Rexec.kill(pid, 15)
      assert_receive {:EXIT, ^pid, {:shutdown, {:signal, 15}}}, 5000
    end
  end

  describe "kill_group/2" do
    test "kills entire process group including children" do
      Process.flag(:trap_exit, true)

      # Spawn a shell that launches a background child, then waits.
      # The shell and its child form a process group.
      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "sleep 60 & sleep 60 & wait"])

      assert is_integer(ospid)

      Rexec.kill_group(pid, :sigterm)
      assert_receive {:EXIT, ^pid, {:shutdown, {:signal, 15}}}, 5000
    end
  end

  describe "lifecycle ownership" do
    for mode <- [:run, :run_link] do
      test "#{mode} cleans escaped descendants when its caller dies" do
        mode = unquote(mode)
        test_pid = self()

        owner =
          spawn(fn ->
            {:ok, pid, ospid} = apply(Rexec, mode, [escaped_command()])
            Kernel.send(test_pid, {:started, self(), pid, ospid})
            relay_output(test_pid)
          end)

        assert_receive {:started, ^owner, pid, ospid}, 5000
        ref = Process.monitor(pid)
        escaped = escaped_pid(ospid)
        assert File.exists?("/proc/#{escaped}")

        Process.exit(owner, :kill)

        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
        refute File.exists?("/proc/#{ospid}")
        refute File.exists?("/proc/#{escaped}")
      end

      test "#{mode} cleans and completes when its caller dies before notification setup" do
        mode = if unquote(mode) == :run_link, do: :link, else: :monitor
        test_pid = self()
        caller = spawn(fn -> relay_output(test_pid) end)
        on_exit(fn -> Process.exit(caller, :kill) end)
        startup_ref = make_ref()

        {:ok, pid} = GenServer.start(Rexec, {escaped_command(), caller, startup_ref, mode, []})
        ref = Process.monitor(pid)
        assert_receive {:rexec_started, ^startup_ref, ^pid, ospid}, 5000
        escaped = escaped_pid(ospid)
        Process.exit(caller, :kill)

        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
        refute File.exists?("/proc/#{ospid}")
        refute File.exists?("/proc/#{escaped}")
      end

      test "#{mode} retains explicit ownership when its caller dies before notification setup" do
        mode = if unquote(mode) == :run_link, do: :link, else: :monitor
        test_pid = self()
        caller = spawn(fn -> relay_output(test_pid) end)
        on_exit(fn -> Process.exit(caller, :kill) end)
        startup_ref = make_ref()

        {:ok, pid} =
          GenServer.start(
            Rexec,
            {escaped_command(), caller, startup_ref, mode, [owner: test_pid]}
          )

        ref = Process.monitor(pid)
        assert_receive {:rexec_started, ^startup_ref, ^pid, ospid}, 5000
        escaped = escaped_pid(ospid)
        Process.exit(caller, :kill)

        if mode == :monitor do
          refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
          assert File.exists?("/proc/#{ospid}")
          assert File.exists?("/proc/#{escaped}")
          :ok = Rexec.kill_tree(pid, :sigkill)
        end

        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
        refute File.exists?("/proc/#{ospid}")
        refute File.exists?("/proc/#{escaped}")
      end

      test "#{mode} returns structured startup errors without killing its caller" do
        mode = unquote(mode)
        test_pid = self()

        {caller, ref} =
          spawn_monitor(fn ->
            result = apply(Rexec, mode, [["/rexec-command-that-does-not-exist"]])
            Kernel.send(test_pid, {:startup_result, self(), result})
          end)

        assert_receive {:startup_result, ^caller, {:error, {:startup, message}}}, 5000
        assert String.valid?(message)
        assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 5000
      end

      test "#{mode} honors an explicit owner distinct from its caller" do
        mode = unquote(mode)
        Process.flag(:trap_exit, true)

        owner =
          spawn(fn ->
            receive do
              :finish -> :ok
            end
          end)

        on_exit(fn -> Process.exit(owner, :kill) end)

        {:ok, pid, ospid} = apply(Rexec, mode, [escaped_command(), [owner: owner]])
        ref = Process.monitor(pid)
        escaped = escaped_pid(ospid)
        Process.exit(owner, :kill)

        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
        refute File.exists?("/proc/#{ospid}")
        refute File.exists?("/proc/#{escaped}")
      end
    end

    test "an explicit owner keeps a monitored command alive after its caller exits" do
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, pid, ospid} = Rexec.run(escaped_command(), owner: test_pid)
          Kernel.send(test_pid, {:started, self(), pid, ospid})
          relay_output(test_pid)
        end)

      assert_receive {:started, ^caller, pid, ospid}, 5000
      ref = Process.monitor(pid)
      escaped = escaped_pid(ospid)
      Process.exit(caller, :kill)

      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
      assert File.exists?("/proc/#{ospid}")
      assert File.exists?("/proc/#{escaped}")

      :ok = Rexec.kill_tree(pid, :sigkill)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
      refute File.exists?("/proc/#{ospid}")
      refute File.exists?("/proc/#{escaped}")
    end

    test "linked caller death cleans the tree even while an explicit owner remains alive" do
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, pid, ospid} = Rexec.run_link(escaped_command(), owner: test_pid)
          Kernel.send(test_pid, {:started, self(), pid, ospid})
          relay_output(test_pid)
        end)

      assert_receive {:started, ^caller, pid, ospid}, 5000
      ref = Process.monitor(pid)
      escaped = escaped_pid(ospid)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
      refute File.exists?("/proc/#{ospid}")
      refute File.exists?("/proc/#{escaped}")
    end

    test "normal GenServer.stop waits for cleanup and forwards buffered output" do
      {:ok, pid, ospid} =
        Rexec.run(
          escaped_command(
            "read ignored; printf 'buffered stderr\\n' >&2; printf 'buffered stdout\\n'; read ignored"
          )
        )

      escaped = escaped_pid(ospid)
      :ok = Rexec.send(pid, "continue\n")
      assert_receive {:stdout, ^ospid, "buffered stdout\n"}, 5000
      :ok = GenServer.stop(pid, :normal, 8000)

      {stdout, stderr, reason} = monitored_output(ospid, pid)
      assert stdout == ""
      assert stderr == "buffered stderr\n"
      assert reason == :normal
      refute File.exists?("/proc/#{ospid}")
      refute File.exists?("/proc/#{escaped}")
    end

    test "completion preserves the direct child's outcome after escaped descendants and pipes close" do
      {:ok, pid, ospid} =
        Rexec.run(
          escaped_command(
            "read ignored; printf 'last stdout\\n'; printf 'last stderr\\n' >&2; exit 23"
          )
        )

      escaped = escaped_pid(ospid)
      :ok = Rexec.send(pid, "continue\n")

      {stdout, stderr, reason} = monitored_output(ospid, pid)
      assert stdout == "last stdout\n"
      assert stderr == "last stderr\n"
      assert reason == {:shutdown, {:exit_status, 23}}
      refute File.exists?("/proc/#{ospid}")
      refute File.exists?("/proc/#{escaped}")
    end

    test "monitoring preserves immediate successful and nonzero outcomes" do
      for status <- [0, 31] do
        {:ok, pid, _ospid} = Rexec.run(["sh", "-c", "exit #{status}"])
        reason = if status == 0, do: :normal, else: {:shutdown, {:exit_status, status}}
        assert_receive {:DOWN, _ref, :process, ^pid, ^reason}, 5000
      end
    end

    test "kill_tree reaches escaped sessions that kill_group leaves alive" do
      command = [
        "sh",
        "-c",
        "trap 'echo direct-signal' USR1; " <>
          "setsid sh -c 'trap \"echo escaped-signal\" USR1; " <>
          "echo escaped:$$; while :; do sleep 60; done' & " <>
          "while :; do read ignored; done"
      ]

      {:ok, pid, ospid} = Rexec.run(command)
      escaped = escaped_pid(ospid)

      :ok = Rexec.kill_group(pid, :sigusr1)
      assert_receive {:stdout, ^ospid, "direct-signal\n"}, 5000
      refute_receive {:stdout, ^ospid, "escaped-signal\n"}, 200
      assert File.exists?("/proc/#{escaped}")

      :ok = Rexec.kill_tree(pid, :sigusr1)
      assert_stdout_line(ospid, "escaped-signal")
      :ok = Rexec.kill_tree(pid, :sigkill)
      assert_receive {:DOWN, _ref, :process, ^pid, {:shutdown, {:signal, 9}}}, 8000
      refute File.exists?("/proc/#{ospid}")
      refute File.exists?("/proc/#{escaped}")
    end
  end

  defp escaped_command(tail \\ "read ignored; wait") do
    [
      "sh",
      "-c",
      "setsid sh -c 'printf \"escaped:%s\\n\" \"$$\"; exec sleep 60' & " <> tail
    ]
  end

  defp escaped_pid(ospid) do
    line = assert_stdout_line(ospid, "escaped:")
    [_, pid] = Regex.run(~r/escaped:(\d+)/, line)
    String.to_integer(pid)
  end

  defp assert_stdout_line(ospid, expected, output \\ "") do
    if String.contains?(output, expected) and String.contains?(output, "\n") do
      output
    else
      receive do
        {:stdout, ^ospid, data} ->
          assert_stdout_line(ospid, expected, output <> data)
      after
        5000 -> flunk("expected stdout #{inspect(expected)}, received #{inspect(output)}")
      end
    end
  end

  defp relay_output(test_pid) do
    receive do
      message ->
        Kernel.send(test_pid, message)
        relay_output(test_pid)
    end
  end

  defp monitored_output(ospid, pid, stdout \\ [], stderr \\ []) do
    receive do
      {:stdout, ^ospid, data} ->
        monitored_output(ospid, pid, [data | stdout], stderr)

      {:stderr, ^ospid, data} ->
        monitored_output(ospid, pid, stdout, [data | stderr])

      {:DOWN, _ref, :process, ^pid, reason} ->
        {
          stdout |> Enum.reverse() |> IO.iodata_to_binary(),
          stderr |> Enum.reverse() |> IO.iodata_to_binary(),
          reason
        }
    after
      8000 -> flunk("process #{inspect(pid)} did not complete")
    end
  end

  # Helpers

  defp collect_stdout(ospid, pid) do
    collect_stdout(ospid, pid, [])
  end

  defp collect_stdout(ospid, pid, acc) do
    receive do
      {:stdout, ^ospid, data} ->
        collect_stdout(ospid, pid, [data | acc])

      {:EXIT, ^pid, _} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    after
      5000 ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp collect_output(ospid, pid) do
    collect_output(ospid, pid, [], [])
  end

  defp collect_output(ospid, pid, stdout, stderr) do
    receive do
      {:stdout, ^ospid, data} ->
        collect_output(ospid, pid, [data | stdout], stderr)

      {:stderr, ^ospid, data} ->
        collect_output(ospid, pid, stdout, [data | stderr])

      {:EXIT, ^pid, _} ->
        {
          stdout |> Enum.reverse() |> IO.iodata_to_binary(),
          stderr |> Enum.reverse() |> IO.iodata_to_binary()
        }
    after
      5000 ->
        {
          stdout |> Enum.reverse() |> IO.iodata_to_binary(),
          stderr |> Enum.reverse() |> IO.iodata_to_binary()
        }
    end
  end
end
