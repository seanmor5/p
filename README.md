# P

Because I just wanted a library that I could use to spawn and send signals to OS processes
without needing to download another binary.

This is a very simple Rust NIF which uses the `nix` package with `std::process::Command` to
spawn processes, send signals, and wait with `waitpid`.

## Installation

You probably don't want to use this, but if you do:

```elixir
def deps do
  [
    {:p, github: "seanmor5/p"}
  ]
end
```

## Usage

Spawn a process:

```elixir
p = P.spawn("sleep", ["10"])
```

Send a signal:

```elixir
p = P.signal(p, :sigterm)
```

Wait for exit:

```elixir
p = P.wait(p)
```

At this time, this library provides no way to interact with the running process (e.g. reading from stdout or writing to stdin).