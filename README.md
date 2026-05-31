# fkill-zig

Native macOS process-killer CLI written in Zig. It is a small reimplementation of the core `fkill-cli` workflow with no third-party runtime dependencies.

## Features

- Kill processes by PID, process name, or TCP port.
- Interactive mode when run without arguments.
- Fuzzy search in interactive mode.
- Optional force kill and force-after-timeout behavior.
- Verbose process argument display.
- Native macOS executable shipped in the npm package; Zig is not required at install time.

## Requirements

- macOS (`darwin`).
- Node.js 18 or newer when installing from npm.

The package currently ships a macOS binary only. Linux and Windows are not supported by this package version.

## Install

```sh
pnpm add -g @cyca/fkill-zig
# or
npm install -g @cyca/fkill-zig
```

Then run:

```sh
fkill --help
```

## Usage

```sh
fkill [<pid|name|:port> ...]
```

Examples:

```sh
fkill 1337
fkill safari
fkill :8080
fkill 1337 safari :8080
fkill
```

Port matches are prefixed with a colon, for example `:8080`.

Running `fkill` without arguments starts interactive mode. In interactive mode, `🚦n%` indicates high CPU usage and `🐏n%` indicates high memory usage.

## Options

```text
--force, -f                         Force kill
--verbose, -v                       Show process arguments
--silent, -s                        Silently kill and always exit with code 0
--force-after-timeout <N>, -t <N>   Force kill processes which did not exit after N seconds
--smart-case                        Case-insensitive unless pattern contains uppercase
--case-sensitive                    Force case-sensitive matching
```

Process-name matching is case-insensitive by default.

## Safety notes

`fkill-zig` sends POSIX signals to local macOS processes. It does not use network services, background daemons, telemetry, or third-party runtime packages.

Killing a process can cause unsaved work to be lost. Prefer the default graceful behavior first, and use `--force` only when a process does not exit normally.

## Build from source

Install dependencies and build the release binary:

```sh
pnpm install
pnpm build
```

Run tests:

```sh
pnpm test
```

Or use Zig directly:

```sh
zig build -Doptimize=ReleaseSmall
zig build test
zig-out/bin/fkill --help
```

## Package contents

The npm package includes:

- `bin/fkill` native macOS executable
- Zig source files under `src/`
- `build.zig` and `build.zig.zon`
- `README.md`
- `LICENSE`

## Release status

This package is currently published as an alpha. The command-line interface is usable, but details may change before a stable `1.0.0` release.

## License

MIT
