# fkill

Zig reimplementation of `fkill-cli` for macOS.

```sh
zig build
zig-out/bin/fkill --help
```

The executable has no third-party runtime dependencies. It uses macOS process
tools and POSIX signals directly.
