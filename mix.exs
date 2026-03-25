defmodule Mix.Tasks.Compile.RexecNative do
  @moduledoc "Compiles the rexec_native Rust binary."

  use Mix.Task.Compiler

  @binary_name "rexec_native"
  @native_root Path.join([File.cwd!(), "native", "rexec_native"])

  @impl true
  def run(_args) do
    target = Path.join([Mix.Project.app_path(), "priv", @binary_name])

    if needs_build?(target) do
      Mix.shell().info("Compiling rexec_native...")

      case System.cmd("cargo", ["build", "--release"],
             cd: @native_root,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          copy_binary(target)
          {:ok, []}

        {output, code} ->
          {:error, [{:error, "cargo build failed (exit #{code}):\n#{output}"}]}
      end
    else
      {:noop, []}
    end
  end

  defp needs_build?(target) do
    if File.exists?(target) do
      if Mix.env() == :prod do
        false
      else
        target_mtime = File.stat!(target).mtime

        Path.wildcard(Path.join(@native_root, "src/**/*.rs"))
        |> Enum.concat([
          Path.join(@native_root, "Cargo.toml"),
          Path.join(@native_root, "Cargo.lock")
        ])
        |> Enum.filter(&File.exists?/1)
        |> Enum.any?(fn src ->
          File.stat!(src).mtime > target_mtime
        end)
      end
    else
      true
    end
  end

  defp copy_binary(dst) do
    src = Path.join([@native_root, "target", "release", @binary_name])
    File.mkdir_p!(Path.dirname(dst))
    File.cp!(src, dst)
    File.chmod!(dst, 0o755)
  end
end

defmodule Rexec.MixProject do
  use Mix.Project

  def project do
    [
      app: :rexec,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: [:rexec_native] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
