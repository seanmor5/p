# P

Simple OS process management for Elixir. Spawn processes, send signals, wait for exit.

Rust NIF using `nix` and `std::process::Command`. Linux only.

## Installation

```elixir
def deps do
  [
    {:p, github: "seanmor5/p"}
  ]
end
```

## Usage

```elixir
# Spawn and wait
{:ok, p} = P.spawn("echo", ["hello"], stdout: :pipe)
{:ok, output} = P.read(p, :stdout)
p = P.wait(p)
p.status  #=> {:exited, 0}

# Or use bang variants
p = P.spawn!("sleep", ["10"])
p = P.signal!(p, :sigterm)
p = P.wait(p)

# Wait with timeout
case P.wait(p, 5000) do
  :timeout ->
    P.signal!(p, :sigkill)
    P.wait(p)
  p -> p
end
```

## Stdio

By default, all stdio goes to `/dev/null`. Options:

- `nil` - /dev/null (default)
- `:pipe` - create pipe for read/write
- `:inherit` - use parent's stdio
- `{:file, path}` - redirect to file

```elixir
# Pipes
p = P.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
P.write(p, "hello")
P.close!(p, :stdin)
{:ok, data} = P.read(p, :stdout)

# Files
p = P.spawn!("myapp", [], stdout: {:file, "/var/log/out.log"})

# Inherit (for interactive programs)
p = P.spawn!("vim", ["file.txt"], stdin: :inherit, stdout: :inherit, stderr: :inherit)
```

## Options

```elixir
P.spawn("cmd", ["args"],
  stdin: :pipe,
  stdout: :pipe,
  stderr: :pipe,
  env: %{"FOO" => "bar"},
  cd: "/tmp"
)
```

## License

Copyright (c) 2025 Sean Moriarity

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
