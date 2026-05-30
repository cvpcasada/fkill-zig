# fkill

Zig reimplementation of `fkill-cli` for macOS.

## Install with npm

```sh
pnpm add -g @cyca/fkill-zig
fkill --help
```

The npm package includes the native macOS executable and does not need Zig at
install time.

## Build from source

```sh
pnpm install
pnpm build
pnpm test
pnpm pack
```

Or use Zig directly:

```sh
zig build
zig-out/bin/fkill --help
```

The executable has no third-party runtime dependencies. It uses macOS process
tools and POSIX signals directly.
