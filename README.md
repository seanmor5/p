# Px

Simple OS process management for Elixir. Spawn processes, send signals, wait for exit.

Rust NIF using `nix` and `std::process::Command`. Linux only.

## Installation

```elixir
def deps do
  [
    {:px, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Spawn and wait
{:ok, p} = Px.spawn("echo", ["hello"], stdout: :pipe)
{:ok, output} = Px.read(p, :stdout)
p = Px.wait(p)
p.status  #=> {:exited, 0}

# Or use bang variants
p = Px.spawn!("sleep", ["10"])
p = Px.signal!(p, :sigterm)
p = Px.wait(p)

# Wait with timeout
with :timeout <- Px.wait(p, 5000) do
  Px.signal!(p, :sigkill)
  Px.wait(p)
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
p = Px.spawn!("cat", [], stdin: :pipe, stdout: :pipe)
Px.write(p, "hello")
Px.close!(p, :stdin)
{:ok, data} = Px.read(p, :stdout)

# Files
p = Px.spawn!("myapp", [], stdout: {:file, "/var/log/out.log"})

# Inherit (for interactive programs)
p = Px.spawn!("vim", ["file.txt"], stdin: :inherit, stdout: :inherit, stderr: :inherit)
```

## Options

```elixir
Px.spawn("cmd", ["args"],
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
