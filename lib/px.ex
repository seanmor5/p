defmodule Px do
  @moduledoc """
  Low-level OS process management for Elixir. Linux only.

  ## Basic Usage

      # Spawn, signal, wait
      p = Px.spawn!("sleep", ["10"])
      p = Px.signal!(p, :sigterm)
      p = Px.wait(p)
      p.status  #=> {:exited, 143}

      # With error handling
      {:ok, p} = Px.spawn("sleep", ["10"])
      {:ok, p} = Px.signal(p, :sigterm)
      p = Px.wait(p)

  ## Stdio Configuration

  By default, stdin/stdout/stderr go to `/dev/null`. Configure per-stream:

  - `nil` - /dev/null (default)
  - `:pipe` - pipe for reading/writing from Elixir
  - `:inherit` - share BEAM's stdio (for interactive programs)
  - `{:file, path}` - redirect to/from file

  ### Fire and Forget

  Default config discards all output. Useful for daemons or when you
  only care about exit status:

      p = Px.spawn!("some-daemon", ["--detach"])
      p = Px.wait(p)

  ### File Redirection

  Let the OS handle buffering. Good for logging:

      p = Px.spawn!("my-server", [],
        stdout: {:file, "/var/log/out.log"},
        stderr: {:file, "/var/log/err.log"})

  ### Pipes

  For reading output or writing input. Non-blocking by default.

      # Capture output
      p = Px.spawn!("echo", ["hello"], stdout: :pipe)
      Process.sleep(50)  # let it run
      {:ok, "hello\\n"} = Px.read(p, :stdout)

      # Feed input
      p = Px.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
      Px.write(p, "hello")
      Px.close!(p, :stdin)  # signals EOF
      Process.sleep(50)
      {:ok, "hello"} = Px.read(p, :stdout)

  **Warning:** Pipes have limited buffer (~64KB). If the child writes more
  than the buffer can hold and you don't read, the child blocks forever.
  Drain pipes continuously for long-running processes.

  ### Inherit

  Child uses BEAM's terminal directly. For interactive programs:

      p = Px.spawn!("vim", ["file.txt"],
        stdin: :inherit,
        stdout: :inherit,
        stderr: :inherit)
      Px.wait(p)

  ## Timeouts

  `wait/2` accepts a timeout in milliseconds:

      case Px.wait(p, 5_000) do
        :timeout ->
          Px.signal!(p, :sigkill)
          Px.wait(p)
        p ->
          p
      end

  ## Environment and Working Directory

      Px.spawn!("make", ["build"],
        cd: "/path/to/project",
        env: %{"CC" => "clang", "CFLAGS" => "-O2"})

  Environment variables are merged with the inherited environment.

  ## Signals

  Signals are sent by name (atom) or number:

      Px.signal!(p, :sigterm)   # graceful shutdown
      Px.signal!(p, :sigkill)   # force kill
      Px.signal!(p, :sigusr1)   # user-defined
      Px.signal!(p, 15)         # by number

  Signal safety: once a process has been reaped (via `alive?/1` or `wait/1`),
  `signal/2` returns `{:error, :already_exited}` to prevent signaling a
  recycled PID.

  ## Non-blocking Reads/Writes

  Pipe operations are non-blocking:

      Px.read(p, :stdout)
      #=> {:ok, binary}    - data available
      #=> :would_block     - no data yet
      #=> :eof             - stream closed

      Px.write(p, data)
      #=> :ok              - all written
      #=> {:partial, n}    - buffer full, n bytes written
      #=> :would_block     - buffer completely full
      #=> {:error, :broken_pipe}  - child closed stdin

  ## Process Lifecycle

  1. `spawn/3` - creates process, returns `{:ok, %Px{status: :running}}`
  2. `alive?/1` - checks if still running (non-blocking)
  3. `signal/2` - sends signal
  4. `wait/1,2` - blocks until exit, updates `status` to `{:exited, code}`

  Exit codes: normal exit returns the code (0-255). Signal termination
  returns 128 + signal number (e.g., SIGKILL=9 → 137).
  """
  import Kernel, except: [spawn: 1, spawn: 3]

  use Rustler, otp_app: :px, crate: "px"

  defstruct [:cmd, :args, :pid, :status, :resource, :stdin, :stdout, :stderr]

  @type stdio_config :: nil | :pipe | :inherit | {:file, Path.t()}

  @type t :: %__MODULE__{
          cmd: String.t(),
          args: [String.t()],
          pid: pos_integer(),
          status: :running | {:exited, integer()},
          resource: reference(),
          stdin: stdio_config(),
          stdout: stdio_config(),
          stderr: stdio_config()
        }

  @doc """
  Spawn an OS process running `cmd` with `args`.

  ## Options

  - `:stdin` - stdin configuration (default: `nil` for /dev/null)
  - `:stdout` - stdout configuration (default: `nil` for /dev/null)
  - `:stderr` - stderr configuration (default: `nil` for /dev/null)
  - `:env` - environment variables as a map (merged with inherited environment)
  - `:cd` - working directory for the child process

  Each stdio option accepts:
  - `nil` - redirect to /dev/null (safe default)
  - `:pipe` - create a pipe (enables `read/2` for stdout/stderr, `write/2` for stdin)
  - `:inherit` - inherit from parent (child uses BEAM's stdio directly)
  - `{:file, path}` - redirect to/from a file

  ## Returns

  - `{:ok, process}` - process spawned successfully
  - `{:error, reason}` - failed to spawn (command not found, file error, etc.)

  ## Examples

      iex> {:ok, p} = Px.spawn("echo", ["hello"], stdout: :pipe)
      iex> Process.sleep(50)
      iex> Px.read(p, :stdout)
      {:ok, "hello\\n"}

      iex> Px.spawn("nonexistent_command_12345", [])
      {:error, "Failed to spawn: No such file or directory (os error 2)"}
  """
  def spawn(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    ensure_sigchild()

    stdin = Keyword.get(opts, :stdin, nil)
    stdout = Keyword.get(opts, :stdout, nil)
    stderr = Keyword.get(opts, :stderr, nil)
    env = Keyword.get(opts, :env, %{})
    cd = Keyword.get(opts, :cd, nil)

    {stdin_mode, stdin_path} = encode_stdio(stdin)
    {stdout_mode, stdout_path} = encode_stdio(stdout)
    {stderr_mode, stderr_path} = encode_stdio(stderr)
    env_list = encode_env(env)
    cd_str = cd || ""

    with {resource, pid} when is_reference(resource) and is_integer(pid) <-
           spawn_nif(
             cmd,
             args,
             stdin_mode,
             stdin_path,
             stdout_mode,
             stdout_path,
             stderr_mode,
             stderr_path,
             env_list,
             cd_str
           ) do
      {:ok,
       struct(__MODULE__,
         cmd: cmd,
         args: args,
         pid: pid,
         resource: resource,
         status: :running,
         stdin: stdin,
         stdout: stdout,
         stderr: stderr
       )}
    end
  end

  @doc """
  Spawn an OS process, raising on failure.

  Same as `spawn/3` but raises on error instead of returning `{:error, reason}`.

  ## Examples

      iex> p = Px.spawn!("echo", ["hello"], stdout: :pipe)
      iex> p.status
      :running
  """
  def spawn!(cmd, args, opts \\ []) do
    case spawn(cmd, args, opts) do
      {:ok, process} -> process
      {:error, reason} -> raise "Failed to spawn #{cmd}: #{inspect(reason)}"
    end
  end

  @doc """
  Send `signal` to the given process.

  ## Returns

  - `{:ok, process}` - signal was sent successfully
  - `{:error, :already_exited}` - process has already exited and been reaped
  - `{:error, reason}` - other error (e.g., permission denied)

  ## Safety

  This function is safe against PID reuse. It checks that the process hasn't
  been reaped (by `alive?/1` or `wait/1`) before sending the signal. This
  prevents accidentally signaling an unrelated process that reused the PID.

  ## Examples

      iex> {:ok, p} = Px.spawn("sleep", ["10"])
      iex> {:ok, p} = Px.signal(p, :sigterm)
      iex> p = Px.wait(p)
      iex> p.status
      {:exited, 143}

      # Signal after alive? returns false
      iex> {:ok, p} = Px.spawn("true", [])
      iex> Process.sleep(50)
      iex> Px.alive?(p)
      false
      iex> Px.signal(p, :sigterm)
      {:error, :already_exited}
  """
  def signal(%__MODULE__{resource: resource, status: status} = process, signal)
      when is_atom(signal) or (is_integer(signal) and signal > 0) do
    ensure_sigchild()

    case status do
      {:exited, _} ->
        {:error, :already_exited}

      :running ->
        case signal_nif(resource, signal_int(signal)) do
          :ok -> {:ok, process}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Send `signal` to the given process, raising on failure.

  Same as `signal/2` but raises on error instead of returning `{:error, reason}`.

  ## Examples

      iex> p = Px.spawn!("sleep", ["10"])
      iex> p = Px.signal!(p, :sigterm)
      iex> p = Px.wait(p)
      iex> p.status
      {:exited, 143}
  """
  def signal!(%__MODULE__{} = process, signal) do
    case signal(process, signal) do
      {:ok, process} -> process
      {:error, reason} -> raise "Failed to signal process: #{inspect(reason)}"
    end
  end

  @doc """
  Wait for the given process to complete.

  ## Options

  With one argument, blocks indefinitely until the process exits.
  With a timeout (in milliseconds), returns `:timeout` if the process
  doesn't exit within the specified time.

  ## Examples

      # Block forever
      iex> p = Px.spawn!("sleep", ["0.1"])
      iex> p.status
      :running
      iex> p = Px.wait(p)
      iex> p.status
      {:exited, 0}

      # With timeout
      iex> p = Px.spawn!("sleep", ["10"])
      iex> Px.wait(p, 100)
      :timeout

      # Typical timeout + kill pattern
      iex> p = Px.spawn!("sleep", ["10"])
      iex> p = case Px.wait(p, 100) do
      ...>   :timeout ->
      ...>     Px.signal!(p, :sigkill)
      ...>     Px.wait(p)
      ...>   result -> result
      ...> end
      iex> p.status
      {:exited, 137}
  """
  def wait(process, timeout \\ :infinity)

  def wait(%__MODULE__{resource: resource, status: status} = process, :infinity) do
    ensure_sigchild()

    case status do
      {:exited, _} ->
        process

      :running ->
        code = wait_nif(resource)
        %{process | status: {:exited, code}}

      nil ->
        raise "Invalid process state"
    end
  end

  def wait(%__MODULE__{status: {:exited, _}} = process, _timeout), do: process

  def wait(%__MODULE__{status: :running} = process, timeout)
      when is_integer(timeout) and timeout >= 0 do
    ensure_sigchild()
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_wait(process, deadline)
  end

  defp poll_wait(process, deadline) do
    if alive?(process) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(remaining, 10))
        poll_wait(process, deadline)
      else
        :timeout
      end
    else
      wait(process)
    end
  end

  @doc """
  Check if the process is still alive.

  ## Examples

      iex> p = Px.spawn!("sleep", ["10"])
      iex> Px.alive?(p)
      true
      iex> Px.signal!(p, :sigterm)
      iex> Px.wait(p)
      iex> Px.alive?(p)
      false
  """
  def alive?(%__MODULE__{resource: resource, status: :running}) do
    alive_nif(resource)
  end

  def alive?(%__MODULE__{status: {:exited, _}}), do: false

  @doc """
  Write data to the process stdin.

  Requires the process to be spawned with `stdin: :pipe`.

  ## Returns

  - `:ok` - all bytes written successfully
  - `{:partial, bytes_written}` - only some bytes written (buffer full)
  - `:would_block` - no bytes written, buffer completely full
  - `{:error, :not_piped}` - stdin was not configured as `:pipe`
  - `{:error, :broken_pipe}` - child closed stdin or exited
  - `{:error, reason}` - other IO error

  ## Examples

      iex> p = Px.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
      iex> Px.write(p, "hello")
      :ok
      iex> Px.close!(p, :stdin)
      :ok
      iex> Process.sleep(50)
      iex> Px.read(p, :stdout)
      {:ok, "hello"}
  """
  def write(%__MODULE__{stdin: :pipe, resource: resource}, data) when is_binary(data) do
    write_stdin_nif(resource, data)
  end

  def write(%__MODULE__{}, _data), do: {:error, :not_piped}

  @doc """
  Close a pipe to/from the child process.

  ## Streams

  - `:stdin` - Closes the write end of stdin, signaling EOF to the child.
    Many programs (cat, grep, sort, etc.) wait for stdin EOF before processing.

  - `:stdout` - Closes the read end of stdout. The child will receive SIGPIPE
    or get EPIPE on its next write to stdout, which typically causes it to exit.

  - `:stderr` - Closes the read end of stderr. Same behavior as stdout.

  ## Warning

  Closing `:stdout` or `:stderr` is a forceful operation. The child process
  will receive SIGPIPE (default: terminate) when it tries to write. Only use
  this when you intentionally want to signal the child to stop writing.

  ## Returns

  - `:ok` - pipe closed successfully
  - `{:error, :not_piped}` - stream was not configured as `:pipe`

  ## Examples

      iex> {:ok, p} = Px.spawn("cat", [], stdin: :pipe, stdout: :pipe)
      iex> Px.write(p, "data")
      :ok
      iex> Px.close(p, :stdin)
      :ok
  """
  def close(%__MODULE__{stdin: :pipe, resource: resource}, :stdin) do
    close_stdin_nif(resource)
  end

  def close(%__MODULE__{stdout: :pipe, resource: resource}, :stdout) do
    close_stdout_nif(resource)
  end

  def close(%__MODULE__{stderr: :pipe, resource: resource}, :stderr) do
    close_stderr_nif(resource)
  end

  def close(%__MODULE__{}, _stream), do: {:error, :not_piped}

  @doc """
  Close a pipe to/from the child process, raising on failure.

  Same as `close/2` but raises on error instead of returning `{:error, reason}`.

  ## Examples

      iex> p = Px.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
      iex> Px.write(p, "data")
      :ok
      iex> Px.close!(p, :stdin)
      :ok
  """
  def close!(%__MODULE__{} = process, stream) do
    case close(process, stream) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to close #{stream}: #{inspect(reason)}"
    end
  end

  @doc """
  Read from the process stdout or stderr.

  Requires the process to be spawned with `stdout: :pipe` or `stderr: :pipe`.

  ## Returns

  - `{:ok, binary}` - data was read successfully
  - `:eof` - the stream has been closed
  - `:would_block` - no data available right now (non-blocking)
  - `{:error, :not_piped}` - stream was not configured as `:pipe`
  - `{:error, reason}` - an error occurred

  ## Examples

      iex> p = Px.spawn!("echo", ["hello"], stdout: :pipe)
      iex> Process.sleep(50)
      iex> Px.read(p, :stdout)
      {:ok, "hello\\n"}

      iex> p = Px.spawn!("sh", ["-c", "echo error >&2"], stderr: :pipe)
      iex> Process.sleep(50)
      iex> Px.read(p, :stderr)
      {:ok, "error\\n"}

      iex> {:ok, p} = Px.spawn("echo", ["hello"])  # no pipe configured
      iex> Px.read(p, :stdout)
      {:error, :not_piped}
  """
  def read(%__MODULE__{stdout: :pipe, resource: resource}, :stdout) do
    read_stdout_nif(resource)
  end

  def read(%__MODULE__{stderr: :pipe, resource: resource}, :stderr) do
    read_stderr_nif(resource)
  end

  def read(%__MODULE__{}, _stream), do: {:error, :not_piped}

  @doc false
  def spawn_nif(
        _cmd,
        _args,
        _stdin_mode,
        _stdin_path,
        _stdout_mode,
        _stdout_path,
        _stderr_mode,
        _stderr_path,
        _env,
        _cd
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def signal_nif(_resource, _signal), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def wait_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def alive_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def write_stdin_nif(_resource, _data), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def close_stdin_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def close_stdout_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def close_stderr_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def read_stdout_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def read_stderr_nif(_resource), do: :erlang.nif_error(:nif_not_loaded)

  defp ensure_sigchild() do
    with nil <- :persistent_term.get({__MODULE__, :sigchld}, nil) do
      case :os.type() do
        {:win32, _} -> :ok
        _ -> :os.set_signal(:sigchld, :default)
      end

      :persistent_term.put({__MODULE__, :sigchld}, :set)
    end
  end

  defp encode_stdio(nil), do: {"null", ""}
  defp encode_stdio(:pipe), do: {"pipe", ""}
  defp encode_stdio(:inherit), do: {"inherit", ""}
  defp encode_stdio({:file, path}) when is_binary(path), do: {"file", path}

  defp encode_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp encode_env(env) when is_list(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
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
