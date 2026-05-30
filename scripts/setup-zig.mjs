#!/usr/bin/env node
import { chmodSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const version = process.env.ZIG_VERSION ?? "0.16.0";
const installDir = join(root, ".zig-local");
const binary = join(installDir, "zig");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    ...options,
  });

  if (result.error) {
    throw result.error;
  }

  return result;
}

function commandExists(command) {
  return run("sh", ["-lc", `command -v ${command}`]).status === 0;
}

if (commandExists("zig")) {
  const result = run("zig", ["version"]);
  process.stdout.write(`Using system Zig ${result.stdout.trim()}.\n`);
  process.exit(0);
}

if (existsSync(binary)) {
  const result = run(binary, ["version"]);
  process.stdout.write(`Using local Zig ${result.stdout.trim()}.\n`);
  process.exit(0);
}

const arch = {
  arm64: "aarch64",
  x64: "x86_64",
}[process.arch];

const platform = {
  darwin: "macos",
  linux: "linux",
}[process.platform];

if (!arch || !platform) {
  throw new Error(`Unsupported platform for local Zig: ${process.platform} ${process.arch}`);
}

const response = await fetch("https://ziglang.org/download/index.json");
if (!response.ok) {
  throw new Error(`Failed to fetch Zig download index: ${response.status}`);
}

const index = await response.json();
const release = index[version]?.[`${arch}-${platform}`];
if (!release?.tarball) {
  throw new Error(`Zig ${version} is not available for ${arch}-${platform}`);
}

const tmpDir = join(root, ".zig-local-tmp");
const archive = join(tmpDir, "zig.tar.xz");

rmSync(tmpDir, { recursive: true, force: true });
mkdirSync(tmpDir, { recursive: true });

process.stdout.write(`Installing Zig ${version} locally...\n`);
run("curl", ["-fsSL", release.tarball, "-o", archive], { stdio: "inherit" });

rmSync(installDir, { recursive: true, force: true });
mkdirSync(installDir, { recursive: true });
run("tar", ["-xJf", archive, "-C", installDir, "--strip-components=1"], { stdio: "inherit" });
chmodSync(binary, 0o755);
rmSync(tmpDir, { recursive: true, force: true });

process.stdout.write(`Installed local Zig ${version}.\n`);
