defmodule JX.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        JX.Repo,
        {Task.Supervisor, name: JX.TaskSupervisor},
        JX.Jido,
        JX.OrchestratorRuntime,
        JX.DevIDE.RunnerReconciler,
        JX.HostCapacity.CapacityPoller
      ] ++ JX.OrchestratorMonitorSensor.child_specs()

    opts = [strategy: :one_for_one, name: JX.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    maybe_burrito_dispatch()

    {:ok, pid}
  end

  defp maybe_burrito_dispatch do
    if burrito_running?() do
      # Supervised so a CLI crash is logged rather than swallowed silently.
      # The try/rescue ensures System.stop is always called — without it, an
      # exception in JX.CLI.main hangs the BEAM forever with no exit code.
      Task.Supervisor.start_child(JX.TaskSupervisor, fn ->
        try do
          args = apply(Burrito.Util.Args, :get_arguments, [])
          JX.CLI.main(args)
          System.stop(0)
        rescue
          error ->
            IO.puts(:stderr, "jx: fatal error: #{Exception.message(error)}")
            System.stop(1)
        end
      end)
    end
  end

  defp burrito_running? do
    case Code.ensure_loaded(Burrito.Util.Args) do
      {:module, _} ->
        function_exported?(Burrito.Util.Args, :running_standalone?, 0) and
          apply(Burrito.Util.Args, :running_standalone?, [])

      _ ->
        false
    end
  end
end
