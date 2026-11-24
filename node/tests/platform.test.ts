// The platform package: its name for each host, and the directory
// require.resolve finds it in. A host with no package, a package that is not
// installed and one that cannot be resolved are LibraryLoadErrors with
// messages that say what to do.

import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import type { Host } from "../src/cpu.ts";
import { LibraryLoadError } from "../src/errors.ts";
import { ADDON, NATIVE, PACKAGE, PLATFORM_PACKAGE_NAMES, defaultHost, platformPackage, platformPackageDir } from "../src/platform.ts";
import { PLATFORM_DIR, refused, scratch } from "./helpers.ts";

function host(system: string, machine: string, glibc: boolean): Host {
  return { system, machine, glibc, cpuinfo: "/nonexistent" };
}

test("the package is named @komira-ai/komira, a placeholder until the npm name is decided", () => {
  assert.equal(PACKAGE, "@komira-ai/komira");
  assert.equal(ADDON, "komira_addon.node");
  assert.equal(NATIVE, "native");
});

test("each release platform has its package: Linux x64 and arm64 with glibc, macOS arm64", () => {
  assert.equal(platformPackage(host("linux", "x64", true)), "@komira-ai/komira-linux-x64-gnu");
  assert.equal(platformPackage(host("linux", "arm64", true)), "@komira-ai/komira-linux-arm64-gnu");
  assert.equal(platformPackage(host("darwin", "arm64", false)), "@komira-ai/komira-darwin-arm64");
  // glibc is a Linux question only.
  assert.equal(platformPackage(host("darwin", "arm64", true)), "@komira-ai/komira-darwin-arm64");
  assert.deepEqual(PLATFORM_PACKAGE_NAMES, [
    "@komira-ai/komira-linux-x64-gnu",
    "@komira-ai/komira-linux-arm64-gnu",
    "@komira-ai/komira-darwin-arm64",
  ]);
});

test("a host with no package is refused by name", () => {
  const tail = ": its packages are for Linux on x64 and arm64 with glibc, and for macOS on arm64";
  const cases: [Host, string][] = [
    [host("linux", "x64", false), "komira has no native package for linux x64 without glibc"],
    [host("linux", "arm64", false), "komira has no native package for linux arm64 without glibc"],
    [host("linux", "riscv64", true), "komira has no native package for linux riscv64"],
    [host("darwin", "x64", false), "komira has no native package for darwin x64"],
    [host("win32", "x64", false), "komira has no native package for win32 x64"],
  ];
  for (const [h, want] of cases) {
    assert.equal(refused(() => platformPackage(h), LibraryLoadError), want + tail);
  }
});

/** A directory with `node_modules/<name>/package.json` holding `manifest`, and a module in it to resolve from. */
function installed(name: string, manifest: object): { from: string; dir: string } {
  const root = scratch();
  const dir = path.join(root, "node_modules", ...name.split("/"));
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "package.json"), JSON.stringify(manifest));
  return { from: path.join(root, "main.js"), dir };
}

test("an installed platform package is found as a dependency of the module resolving it", () => {
  const name = "@komira-ai/komira-linux-x64-gnu";
  const { from, dir } = installed(name, { name, version: "0.0.0" });
  assert.equal(platformPackageDir(name, from), dir);
  assert.equal(platformPackageDir(name, pathToFileURL(from)), dir);
});

test("by default it is found beside this package: the staged platform package", () => {
  assert.equal(platformPackageDir("@komira-ai/komira-linux-x64-gnu"), PLATFORM_DIR);
});

test("a platform package that is not installed says how to install it", () => {
  const from = path.join(scratch(), "main.js");
  const got = refused(() => platformPackageDir("@komira-ai/komira-linux-arm64-gnu", from), LibraryLoadError);
  assert.equal(
    got,
    "the package @komira-ai/komira-linux-arm64-gnu, which holds libkomira for this platform, is not installed. " +
      "npm installs it with @komira-ai/komira unless optional dependencies are left out (--omit=optional or " +
      "--no-optional): install @komira-ai/komira again without that option",
  );
});

test("a platform package that cannot be resolved for another reason carries the resolver's message", () => {
  const name = "@komira-ai/komira-darwin-arm64";
  const { from, dir } = installed(name, { name, version: "0.0.0", exports: { ".": "./index.js" } });
  const got = refused(() => platformPackageDir(name, from), LibraryLoadError);
  assert.equal(
    got,
    `cannot resolve the package ${name}: Package subpath './package.json' is not defined by "exports" in ` +
      `${path.join(dir, "package.json")}`,
  );
});

test("the default host is this process's: Linux on x64 with glibc, and /proc/cpuinfo", () => {
  // node_binding_test runs on linux x86_64 only, with the pinned glibc build of node.
  assert.deepEqual(defaultHost(), { system: "linux", machine: "x64", glibc: true, cpuinfo: "/proc/cpuinfo" });
});
