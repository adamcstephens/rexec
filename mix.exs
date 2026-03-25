defmodule Mix.Tasks.Compile.RexecNative do
  @moduledoc "Compiles the rexec_native Rust binary."

  use Mix.Task.Compiler

  @native_dir "native/rexec_native"

  @impl true
  def run(_args) do
    native_dir = Path.join(File.cwd!(), @native_dir)
    priv_dir = Path.join(File.cwd!(), "priv")
    File.mkdir_p!(priv_dir)

    target = Path.join(priv_dir, "rexec_native")
    manifest = Path.join(native_dir, "target/release/rexec_native")

    if needs_build?(target, native_dir) do
      Mix.shell().info("Compiling rexec_native...")

      case System.cmd("cargo", ["build", "--release"],
             cd: native_dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          File.cp!(manifest, target)
          File.chmod!(target, 0o755)
          {:ok, []}

        {output, code} ->
          {:error, [{:error, "cargo build failed (exit #{code}):\n#{output}"}]}
      end
    else
      {:noop, []}
    end
  end

  defp needs_build?(target, native_dir) do
    if File.exists?(target) do
      if Mix.env() == :prod do
        false
      else
        target_mtime = File.stat!(target).mtime

        Path.wildcard(Path.join(native_dir, "src/**/*.rs"))
        |> Enum.concat([Path.join(native_dir, "Cargo.toml"), Path.join(native_dir, "Cargo.lock")])
        |> Enum.filter(&File.exists?/1)
        |> Enum.any?(fn src ->
          File.stat!(src).mtime > target_mtime
        end)
      end
    else
      true
    end
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
