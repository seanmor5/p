defmodule PTest do
  use ExUnit.Case
  doctest P

  test "spawns a process and waits for it" do
    p = P.spawn("echo", ["hello"])
    assert p.status == :running
    assert P.alive?(p) == true

    # Wait a bit for the process to do its thing
    Process.sleep(100)

    # It might have exited already, or not.
    # But wait should return the exit code.
    p = P.wait(p)
    assert p.status == {:exited, 0}
    assert P.alive?(p) == false
  end

  test "captures stdout" do
    p = P.spawn("echo", ["hello world"])
    # Give it a moment to write to the pipe
    Process.sleep(50)
    assert P.read_stdout(p) == "hello world\n"
    p = P.wait(p)
    assert p.status == {:exited, 0}
  end

  test "writes to stdin" do
    p = P.spawn("cat", [])
    assert P.alive?(p)

    P.write_stdin(p, "hello from stdin")
    # We need to close stdin or signal EOF for cat to flush/exit if we were just waiting,
    # but here we can read back what we wrote if cat echoes it.
    # Actually cat echoes immediately.

    Process.sleep(50)
    assert P.read_stdout(p) == "hello from stdin"

    P.signal(p, :sigterm)
    p = P.wait(p)
    assert match?({:exited, _}, p.status)
  end

  test "checks alive status" do
    p = P.spawn("sleep", ["1"])
    assert P.alive?(p)
    p = P.wait(p)
    assert not P.alive?(p)
  end
end
