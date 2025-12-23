defmodule PxTest do
  use ExUnit.Case
  doctest Px

  describe "spawn/wait basics" do
    test "spawns a process and waits for it" do
      p = Px.spawn!("true", [])
      assert p.status == :running
      assert Px.alive?(p) == true

      p = Px.wait(p)
      assert p.status == {:exited, 0}
      assert Px.alive?(p) == false
    end

    test "captures exit code" do
      p = Px.spawn!("sh", ["-c", "exit 42"])
      p = Px.wait(p)
      assert p.status == {:exited, 42}
    end

    test "checks alive status" do
      p = Px.spawn!("sleep", ["1"])
      assert Px.alive?(p)
      p = Px.wait(p)
      assert not Px.alive?(p)
    end
  end

  describe "wait with timeout" do
    test "returns :timeout when process doesn't exit in time" do
      p = Px.spawn!("sleep", ["10"])
      assert Px.wait(p, 50) == :timeout
      # Clean up
      {:ok, _} = Px.signal(p, :sigkill)
      Px.wait(p)
    end

    test "returns process when it exits before timeout" do
      p = Px.spawn!("true", [])
      Process.sleep(50)
      p = Px.wait(p, 1000)
      assert p.status == {:exited, 0}
    end

    test "timeout of 0 checks immediately" do
      p = Px.spawn!("sleep", ["10"])
      assert Px.wait(p, 0) == :timeout
      {:ok, _} = Px.signal(p, :sigkill)
      Px.wait(p)
    end

    test "timeout with already exited process returns immediately" do
      p = Px.spawn!("true", [])
      Process.sleep(50)
      # Process should have exited
      p = Px.wait(p, 0)
      assert p.status == {:exited, 0}
    end

    test "timeout + kill pattern" do
      p = Px.spawn!("sleep", ["10"])

      p =
        case Px.wait(p, 50) do
          :timeout ->
            {:ok, _} = Px.signal(p, :sigkill)
            Px.wait(p)

          p ->
            p
        end

      assert p.status == {:exited, 137}
    end

    test "infinity timeout waits forever (like wait/1)" do
      p = Px.spawn!("sh", ["-c", "exit 42"])
      p = Px.wait(p, :infinity)
      assert p.status == {:exited, 42}
    end

    test "process that exits during wait is captured" do
      # Process exits after 100ms, we wait for 500ms
      p = Px.spawn!("sleep", ["0.1"])
      p = Px.wait(p, 500)
      assert p.status == {:exited, 0}
    end

    test "multiple timeouts on same process" do
      p = Px.spawn!("sleep", ["10"])
      assert Px.wait(p, 20) == :timeout
      assert Px.wait(p, 20) == :timeout
      assert Px.wait(p, 20) == :timeout
      {:ok, _} = Px.signal(p, :sigkill)
      Px.wait(p)
    end
  end

  describe "signals" do
    test "sends signal to process" do
      p = Px.spawn!("sleep", ["10"])
      assert p.status == :running
      assert {:ok, p} = Px.signal(p, :sigterm)
      assert p.status == :running
      p = Px.wait(p)
      assert p.status == {:exited, 143}
    end

    test "sigkill" do
      p = Px.spawn!("sleep", ["10"])
      assert {:ok, _} = Px.signal(p, :sigkill)
      p = Px.wait(p)
      assert p.status == {:exited, 137}
    end

    test "signal after wait returns error" do
      p = Px.spawn!("true", [])
      p = Px.wait(p)
      assert Px.signal(p, :sigterm) == {:error, :already_exited}
    end

    test "signal after alive? returns false gives error (PID reuse safety)" do
      p = Px.spawn!("true", [])
      Process.sleep(50)
      # Process exited, alive? will reap the zombie
      assert Px.alive?(p) == false
      # Now signal should refuse (process reaped, PID could be recycled)
      assert Px.signal(p, :sigterm) == {:error, :already_exited}
    end

    test "signal to running process then alive? then signal again" do
      p = Px.spawn!("sleep", ["10"])
      assert {:ok, _} = Px.signal(p, :sigterm)
      Process.sleep(50)
      # Process should have exited from SIGTERM
      assert Px.alive?(p) == false
      # Second signal should fail (process reaped)
      assert Px.signal(p, :sigterm) == {:error, :already_exited}
      Px.wait(p)
    end
  end

  describe "stdout piping" do
    test "captures stdout when piped" do
      p = Px.spawn!("echo", ["hello world"], stdout: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "hello world\n"}
      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "returns :not_piped when stdout not configured" do
      p = Px.spawn!("echo", ["hello"])
      assert Px.read(p, :stdout) == {:error, :not_piped}
      Px.wait(p)
    end

    test "read returns :would_block when no data available" do
      p = Px.spawn!("sh", ["-c", "sleep 1; echo done"], stdout: :pipe)
      assert Px.read(p, :stdout) == :would_block
      {:ok, _} = Px.signal(p, :sigterm)
      Px.wait(p)
    end

    test "read returns :eof after process exits and stream is drained" do
      p = Px.spawn!("echo", ["hello"], stdout: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "hello\n"}
      Px.wait(p)
      assert Px.read(p, :stdout) == :eof
    end

    test "handles large output with multiple reads" do
      # Generate 10KB of output (more than 4096 byte buffer)
      p =
        Px.spawn!("sh", ["-c", "dd if=/dev/zero bs=1024 count=10 2>/dev/null | tr '\\0' 'A'"],
          stdout: :pipe
        )

      Process.sleep(100)

      output = collect_stdout(p)
      Px.wait(p)

      assert byte_size(output) == 10 * 1024
      assert String.match?(output, ~r/^A+$/)
    end

    test "handles binary data (non-UTF8)" do
      p = Px.spawn!("printf", ["\\000\\001\\002\\377"], stdout: :pipe)
      Process.sleep(50)
      assert {:ok, data} = Px.read(p, :stdout)
      assert data == <<0, 1, 2, 255>>
      Px.wait(p)
    end
  end

  describe "stderr piping" do
    test "captures stderr when piped" do
      p = Px.spawn!("sh", ["-c", "echo error message >&2"], stderr: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stderr) == {:ok, "error message\n"}
      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "returns :not_piped when stderr not configured" do
      p = Px.spawn!("sh", ["-c", "echo error >&2"])
      assert Px.read(p, :stderr) == {:error, :not_piped}
      Px.wait(p)
    end

    test "captures both stdout and stderr separately" do
      p = Px.spawn!("sh", ["-c", "echo stdout; echo stderr >&2"], stdout: :pipe, stderr: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "stdout\n"}
      assert Px.read(p, :stderr) == {:ok, "stderr\n"}
      Px.wait(p)
    end
  end

  describe "stdin piping" do
    test "writes to stdin" do
      p = Px.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
      assert Px.write(p, "hello") == :ok
      Px.close(p, :stdin)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "hello"}
      Px.wait(p)
    end

    test "returns :not_piped when stdin not configured" do
      p = Px.spawn!("cat", [])
      assert Px.write(p, "hello") == {:error, :not_piped}
      Px.wait(p)
    end

    test "close returns :not_piped when not configured" do
      p = Px.spawn!("cat", [])
      assert Px.close(p, :stdin) == {:error, :not_piped}
      assert Px.close(p, :stdout) == {:error, :not_piped}
      assert Px.close(p, :stderr) == {:error, :not_piped}
      {:ok, _} = Px.signal(p, :sigterm)
      Px.wait(p)
    end

    test "close stdin signals EOF to child" do
      # wc -c counts bytes and exits after EOF
      p = Px.spawn!("wc", ["-c"], stdin: :pipe, stdout: :pipe)
      Px.write(p, "12345")
      Px.close(p, :stdin)
      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "write returns broken_pipe after child exits" do
      p = Px.spawn!("true", [], stdin: :pipe)
      Process.sleep(50)
      Px.wait(p)
      # Process has exited, write should fail
      assert Px.write(p, "data") == {:error, :broken_pipe}
    end

    test "close stdout causes SIGPIPE on child write" do
      # yes writes "y\n" forever until it gets SIGPIPE
      p = Px.spawn!("yes", [], stdout: :pipe)
      Process.sleep(50)
      # Close stdout - child will get SIGPIPE on next write
      assert Px.close(p, :stdout) == :ok
      # Child should exit due to SIGPIPE (128 + 13 = 141)
      p = Px.wait(p)
      assert p.status == {:exited, 141}
    end
  end

  describe "file redirection" do
    test "stdout to file" do
      path = "/tmp/p_test_stdout_#{:rand.uniform(100_000)}.log"

      try do
        p = Px.spawn!("echo", ["file output"], stdout: {:file, path})
        Px.wait(p)

        assert File.read!(path) == "file output\n"
      after
        File.rm(path)
      end
    end

    test "stderr to file" do
      path = "/tmp/p_test_stderr_#{:rand.uniform(100_000)}.log"

      try do
        p = Px.spawn!("sh", ["-c", "echo error >&2"], stderr: {:file, path})
        Px.wait(p)

        assert File.read!(path) == "error\n"
      after
        File.rm(path)
      end
    end

    test "stdin from file" do
      in_path = "/tmp/p_test_stdin_#{:rand.uniform(100_000)}.txt"
      File.write!(in_path, "file input")

      try do
        p = Px.spawn!("cat", [], stdin: {:file, in_path}, stdout: :pipe)
        Process.sleep(50)
        assert Px.read(p, :stdout) == {:ok, "file input"}
        Px.wait(p)
      after
        File.rm(in_path)
      end
    end

    test "read returns :not_piped for file-based stdout" do
      path = "/tmp/p_test_file_#{:rand.uniform(100_000)}.log"

      try do
        p = Px.spawn!("echo", ["test"], stdout: {:file, path})
        assert Px.read(p, :stdout) == {:error, :not_piped}
        Px.wait(p)
      after
        File.rm(path)
      end
    end
  end

  describe "exit code caching" do
    test "alive? followed by wait preserves exit code" do
      p = Px.spawn!("sh", ["-c", "exit 42"])
      Process.sleep(50)

      # Process should have exited - alive? will reap the zombie
      assert Px.alive?(p) == false

      # wait should still return the correct exit code
      p = Px.wait(p)
      assert p.status == {:exited, 42}
    end

    test "alive? called multiple times after exit is consistent" do
      p = Px.spawn!("true", [])
      Process.sleep(50)

      assert Px.alive?(p) == false
      assert Px.alive?(p) == false
      assert Px.alive?(p) == false

      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "wait works correctly when process killed by signal after alive? check" do
      p = Px.spawn!("sleep", ["10"])
      assert Px.alive?(p) == true

      {:ok, _} = Px.signal(p, :sigkill)
      Process.sleep(50)

      # alive? will reap and cache the signal exit code
      assert Px.alive?(p) == false

      # wait should return 128 + 9 (SIGKILL)
      p = Px.wait(p)
      assert p.status == {:exited, 137}
    end
  end

  describe "default behavior (nil stdio)" do
    test "default spawn has no pipes" do
      p = Px.spawn!("echo", ["hello"])
      assert p.stdin == nil
      assert p.stdout == nil
      assert p.stderr == nil
      assert Px.read(p, :stdout) == {:error, :not_piped}
      assert Px.read(p, :stderr) == {:error, :not_piped}
      assert Px.write(p, "data") == {:error, :not_piped}
      Px.wait(p)
    end
  end

  describe "inherited stdio" do
    test "spawn with inherited stdout runs successfully" do
      # Can't easily capture inherited output, but we can verify it doesn't crash
      p = Px.spawn!("echo", ["inherited"], stdout: :inherit)
      assert p.stdout == :inherit
      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "spawn with all inherited stdio" do
      p = Px.spawn!("true", [], stdin: :inherit, stdout: :inherit, stderr: :inherit)
      assert p.stdin == :inherit
      assert p.stdout == :inherit
      assert p.stderr == :inherit
      p = Px.wait(p)
      assert p.status == {:exited, 0}
    end

    test "read/write return :not_piped for inherited streams" do
      p = Px.spawn!("cat", [], stdin: :inherit, stdout: :inherit, stderr: :inherit)
      assert Px.read(p, :stdout) == {:error, :not_piped}
      assert Px.read(p, :stderr) == {:error, :not_piped}
      assert Px.write(p, "data") == {:error, :not_piped}
      {:ok, _} = Px.signal(p, :sigterm)
      Px.wait(p)
    end

    test "close returns :not_piped for inherited streams" do
      p = Px.spawn!("sleep", ["10"], stdin: :inherit, stdout: :inherit, stderr: :inherit)
      assert Px.close(p, :stdin) == {:error, :not_piped}
      assert Px.close(p, :stdout) == {:error, :not_piped}
      assert Px.close(p, :stderr) == {:error, :not_piped}
      {:ok, _} = Px.signal(p, :sigterm)
      Px.wait(p)
    end

    test "mix inherited and piped" do
      # stdout piped, stderr inherited
      p =
        Px.spawn!("sh", ["-c", "echo piped; echo inherited >&2"], stdout: :pipe, stderr: :inherit)

      Process.sleep(50)
      assert {:ok, "piped\n"} = Px.read(p, :stdout)
      assert Px.read(p, :stderr) == {:error, :not_piped}
      Px.wait(p)
    end
  end

  describe "environment variables" do
    test "sets custom environment variable" do
      p = Px.spawn!("sh", ["-c", "echo $MY_VAR"], env: %{"MY_VAR" => "hello"}, stdout: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "hello\n"}
      Px.wait(p)
    end

    test "sets multiple environment variables" do
      p =
        Px.spawn!("sh", ["-c", "echo $VAR1-$VAR2"],
          env: %{"VAR1" => "foo", "VAR2" => "bar"},
          stdout: :pipe
        )

      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "foo-bar\n"}
      Px.wait(p)
    end

    test "merges with inherited environment" do
      # PATH should still be inherited
      p = Px.spawn!("sh", ["-c", "echo $PATH"], env: %{"MY_VAR" => "test"}, stdout: :pipe)
      Process.sleep(50)
      {:ok, path} = Px.read(p, :stdout)
      assert String.length(path) > 1
      Px.wait(p)
    end

    test "accepts keyword list for env" do
      p = Px.spawn!("sh", ["-c", "echo $MY_VAR"], env: [MY_VAR: "from_keyword"], stdout: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "from_keyword\n"}
      Px.wait(p)
    end

    test "empty env map is fine" do
      p = Px.spawn!("echo", ["test"], env: %{}, stdout: :pipe)
      Process.sleep(50)
      assert Px.read(p, :stdout) == {:ok, "test\n"}
      Px.wait(p)
    end
  end

  describe "working directory" do
    test "runs in specified directory" do
      p = Px.spawn!("pwd", [], cd: "/tmp", stdout: :pipe)
      Process.sleep(50)
      {:ok, output} = Px.read(p, :stdout)
      # macOS /tmp is a symlink to /private/tmp
      assert String.trim(output) in ["/tmp", "/private/tmp"]
      Px.wait(p)
    end

    test "file operations relative to cd" do
      test_dir = "/tmp/p_test_cd_#{:rand.uniform(100_000)}"
      File.mkdir_p!(test_dir)
      File.write!(Path.join(test_dir, "test.txt"), "content")

      try do
        p = Px.spawn!("cat", ["test.txt"], cd: test_dir, stdout: :pipe)
        Process.sleep(50)
        assert Px.read(p, :stdout) == {:ok, "content"}
        Px.wait(p)
      after
        File.rm_rf!(test_dir)
      end
    end

    test "cd with env combined" do
      p =
        Px.spawn!("sh", ["-c", "echo $MY_VAR from $(pwd)"],
          cd: "/tmp",
          env: %{"MY_VAR" => "hello"},
          stdout: :pipe
        )

      Process.sleep(50)
      {:ok, output} = Px.read(p, :stdout)
      # macOS /tmp is a symlink to /private/tmp
      assert output in ["hello from /tmp\n", "hello from /private/tmp\n"]
      Px.wait(p)
    end

    test "nil cd uses current directory" do
      current = File.cwd!()
      p = Px.spawn!("pwd", [], cd: nil, stdout: :pipe)
      Process.sleep(50)
      {:ok, output} = Px.read(p, :stdout)
      assert String.trim(output) == current
      Px.wait(p)
    end
  end

  # Helper to collect all stdout until :eof or :would_block
  defp collect_stdout(p, acc \\ <<>>) do
    case Px.read(p, :stdout) do
      {:ok, data} -> collect_stdout(p, acc <> data)
      :would_block -> acc
      :eof -> acc
    end
  end
end
