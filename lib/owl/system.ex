defmodule Owl.System do
  @moduledoc """
  An alternative to some `System` functions.
  """

  @doc """
  Runs `command` as a daemon, executes `operation` and kills the daemon aftewards.

  Automatically puts messages from `stderr` and `stdout` to `device` prepending them with `prefix`.
  Returns result of invoking `operation`.

  ## Options

  * `:prefix` - a prefix for `stderr` and `stdout` messages from daemon. Defaults to `command` followed by colon.
  * `:device` - device to which messages from `stderr` and `stdout` are put. Defaults to `:stdio`.
  * `:ready_check` - a function which checks the content of the messages produced by `command` before writing to `device`.
    If the function is set, then the execution of the `operation` will be blocked until `ready_check` returns `true`.
    By default this check is absent and `operation` is invoked immediately without awaiting any message.

  ## Example

      ex> Owl.System.daemon_cmd("ping", ["8.8.8.8"], fn ->
      ..>   Process.sleep(3_000)
      ..>   2 + 2
      ..> end)
      # 00:36:33.963 [debug] $ ping 8.8.8.8
      #
      # 00:36:33.964 [debug] Started daemon ping with OS pid 576077
      # ping:  PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
      # ping:  64 bytes from 8.8.8.8: icmp_seq=1 ttl=118 time=28.3 ms
      # ping:  64 bytes from 8.8.8.8: icmp_seq=2 ttl=118 time=26.9 ms
      # ping:  64 bytes from 8.8.8.8: icmp_seq=3 ttl=118 time=28.6 ms

      # 00:36:36.965 [debug] $ kill 576077
      4

      ex> Owl.System.daemon_cmd(
      ..>   "kubectl",
      ..>   [
      ..>     "port-forward",
      ..>     "--namespace=my-app",
      ..>     "--kubeconfig",
      ..>     "~/.kube/myapp",
      ..>     "my-pod",
      ..>     "5432:5432"
      ..>   ],
      ..>   &dump_database/0,
      ..>   prefix: "kubectl(my-pod): ",
      ..>   ready_check: &String.contains?(&1, "Forwarding from")
      ..> )
      # Forwarding from 127.0.0.1:5432 -> 5432
      # Forwarding from [::1]:5432 -> 5432
      :ok
  """
  @spec daemon_cmd(binary(), [binary() | {:secret, binary()}], (() -> result),
          prefix: Owl.Data.t(),
          device: IO.device(),
          ready_check: (String.t() -> boolean())
        ) :: result
        when result: any()
  def daemon_cmd(command, args, operation, options \\ []) when is_function(operation, 0) do
    handle_data_opts =
      case Keyword.get(options, :ready_check) do
        nil ->
          send(self(), :run_operation)
          []

        ready_check when is_function(ready_check, 1) ->
          caller_pid = self()

          [
            handle_data:
              {false,
               fn data, ready? when is_boolean(ready?) ->
                 if ready? do
                   ready?
                 else
                   ready? = ready_check.(data)

                   if ready?, do: send(caller_pid, :run_operation)

                   ready?
                 end
               end}
          ]
      end

    {:ok, pid} =
      Owl.Daemon.start(
        [
          command: command,
          args: args
        ] ++ handle_data_opts ++ Keyword.take(options, [:prefix, :device])
      )

    Process.link(pid)

    try do
      receive do
        :run_operation -> operation.()
      end
    after
      Owl.Daemon.stop(pid)
    end
  end

  @doc """
  A wrapper around `System.cmd/3` which additionally logs executed `command` and `args`.

  If URL is found in logged message, then password in it is masked with asterisks.
  Additionally, it is possible to explicitly mark a whole argument as secret.

  ## Examples

      > Owl.System.cmd("echo", ["test"])
      # 10:25:34.252 [debug] $ echo test
      {"test\\n", 0}

      > Owl.System.cmd("echo", ["hello", secret: "world"])
      # 10:25:40.516 [debug] $ echo hello ********
      {"hello world\\n", 0}

      > Owl.System.cmd("psql", ["postgresql://postgres:postgres@127.0.0.1:5432", "-tAc", "SELECT 1;"])
      # 10:25:50.947 [debug] $ psql postgresql://postgres:********@127.0.0.1:5432 -tAc 'SELECT 1;'
      {"1\\n", 0}

  """
  @spec cmd(binary(), [binary() | {:secret, binary()}], keyword()) ::
          {Collectable.t(), exit_status :: non_neg_integer()}
  def cmd(command, args, opts \\ []) when is_binary(command) and is_list(args) do
    Owl.System.Helpers.log_shell_command(command, args)

    args =
      Enum.map(
        args,
        fn
          {:secret, arg} when is_binary(arg) -> arg
          arg when is_binary(arg) -> arg
        end
      )

    System.cmd(command, args, opts)
  end

  @doc """
  A wrapper around `System.shell/2` which additionally logs executed `command`.

  Similarly to `cmd/3`, it automatically hides password in found URLs.

  ## Examples

      > Owl.System.shell("echo hello world")
      # 22:36:01.440 [debug] $ echo hello world
      {"hello world\\n", 0}

      > Owl.System.shell("echo postgresql://postgres:postgres@127.0.0.1:5432")
      # 22:36:51.797 [debug] $ echo postgresql://postgres:********@127.0.0.1:5432
      {"postgresql://postgres:postgres@127.0.0.1:5432\\n", 0}
  """
  @spec shell(
          binary(),
          keyword()
        ) :: {Collectable.t(), exit_status :: non_neg_integer()}
  def shell(command, opts \\ []) when is_binary(command) do
    Owl.System.Helpers.log_shell_command(command)
    System.shell(command, opts)
  end
end
