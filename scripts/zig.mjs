#!/usr/bin/env node
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const localZig = join(root, ".zig-local", "zig");
const command = existsSync(localZig) ? localZig : "zig";

const result = spawnSync(command, process.argv.slice(2), {
  cwd: root,
  stdio: "inherit",
});

if (result.error?.code === "ENOENT") {
  console.error("Zig is not installed. Run `pnpm install` to install a local Zig compiler.");
  process.exit(1);
}

if (result.error) {
  throw result.error;
}

process.exit(result.status ?? 1);
