defmodule P do
  @moduledoc """
  A simple module for managing OS processes in Elixir.

  For when you just want to spawn a process, send a signal,
  and wait for it to finish.
  """
  use Rustler, otp_app: :p, crate: "p"

  defstruct [:cmd, :args, :pid, :status]

  @doc """
  Spawn an OS process running `cmd` with `args`.

  ## Examples
      
      iex> process = P.spawn("echo", ["test"])
      iex> process.cmd
      "echo"
      iex> process.args
      ["test"]
      iex> process.status
      :running
      iex> process = P.wait(process)
      iex> process.status
      {:exited, 0}
  """
  def spawn(cmd, args) when is_binary(cmd) and is_list(args) do
    ensure_sigchild()

    with pid when is_integer(pid) <- spawn_nif(cmd, args) do
      struct(__MODULE__,
        cmd: cmd,
        args: args,
        pid: pid,
        status: :running
      )
    end
  end

  @doc """
  Send `signal` to the given process.

  ## Examples

      iex> process = P.spawn("sleep", ["10"])
      iex> process.status
      :running
      iex> process = P.signal(process, :sigterm)
      iex> process.status
      :running
      iex> process = P.wait(process)
      iex> process.status
      {:exited, 143}
  """
  def signal(%__MODULE__{pid: pid, status: status} = process, signal)
      when is_atom(signal) or (is_integer(signal) and signal > 0) do
    ensure_sigchild()

    case status do
      {:exited, _} ->
        raise "Process has already exited"

      :running ->
        signal_nif(pid, signal_int(signal))
        process
    end
  end

  @doc """
  Wait for the given process to complete.

      iex> process = P.spawn("sleep", ["1"])
      iex> process.status
      :running
      iex> process = P.wait(process)
      iex> process.status
      {:exited, 0}
  """
  def wait(%__MODULE__{pid: pid, status: status} = process) do
    ensure_sigchild()

    case status do
      {:exited, _} ->
        process

      :running ->
        code = wait_nif(pid)
        %{process | status: {:exited, code}}

      nil ->
        raise "Invalid process state"
    end
  end

  @doc false
  def spawn_nif(_cmd, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def signal_nif(_pid, _signal), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def wait_nif(_pid), do: :erlang.nif_error(:nif_not_loaded)

  defp ensure_sigchild() do
    # waitpid running in the context of the beam is kind of weird
    # because the VM sets sigchld and so calls to waitpid just
    # hang. setting this here prevents this. We don't want to reset
    # on every call, and an application seems overkill for this, so
    # we just cache in persistent term
    with nil <- :persistent_term.get({__MODULE__, :sigchld}, nil) do
      case :os.type() do
        {:win32, _} -> :ok
        _ -> :os.set_signal(:sigchld, :default)
      end

      :persistent_term.put({__MODULE__, :sigchld}, :set)
    end
  end

  defp signal_int(value) when is_integer(value), do: value
  defp signal_int(:sighup), do: 1
  defp signal_int(:sigint), do: 2
  defp signal_int(:sigquit), do: 3
  defp signal_int(:sigill), do: 4
  defp signal_int(:sigtrap), do: 5
  defp signal_int(:sigabrt), do: 6
  defp signal_int(:sigbus), do: 7
  defp signal_int(:sigfpe), do: 8
  defp signal_int(:sigkill), do: 9
  defp signal_int(:sigusr1), do: 10
  defp signal_int(:sigsegv), do: 11
  defp signal_int(:sigusr2), do: 12
  defp signal_int(:sigpipe), do: 13
  defp signal_int(:sigalrm), do: 14
  defp signal_int(:sigterm), do: 15
  defp signal_int(:sigstkflt), do: 16
  defp signal_int(:sigchld), do: 17
  defp signal_int(:sigcont), do: 18
  defp signal_int(:sigstop), do: 19
  defp signal_int(:sigtstp), do: 20
  defp signal_int(:sigttin), do: 21
  defp signal_int(:sigttou), do: 22
  defp signal_int(:sigurg), do: 23
  defp signal_int(:sigxcpu), do: 24
  defp signal_int(:sigxfsz), do: 25
  defp signal_int(:sigvtalrm), do: 26
  defp signal_int(:sigprof), do: 27
  defp signal_int(:sigwinch), do: 28
  defp signal_int(:sigio), do: 29
  defp signal_int(:sigpwr), do: 30
  defp signal_int(:sigsys), do: 31
end
