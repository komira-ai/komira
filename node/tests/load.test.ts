// Loading: the CPU is checked before anything is opened, then the addon, then
// libkomira through the addon, which checks the ABI major version. Each
// refusal is a LibraryLoadError naming the file and leaves nothing loaded, so
// a later load can succeed; the library loaded is then the environment's one.
// The addon holds one library per process and this file is its own process,
// so the refusals come first and the loads last.

import assert from "node:assert/strict";
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { LibraryLoadError, UnsupportedCpuError } from "../src/errors.ts";
import { abiVersion } from "../src/index.ts";
import { load, loadFrom, resetHost, setHost } from "../src/native.ts";
import { ADDON_FILE, LINUX_X64, addonOpened, fake, fixture, refused, scratch } from "./helpers.ts";

const SCRATCH = scratch();

/** A native directory holding `files` ({path in it: file to copy}). */
function nativeDir(name: string, files: Record<string, string>): string {
  const d = path.join(SCRATCH, name);
  for (const [rel, from] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
    copyFileSync(from, path.join(d, rel));
  }
  return d;
}

const V1 = path.join(fake("v1_1"), "libkomira.so");
const V2 = path.join(fake("v2"), "libkomira.so");

test("a host with no platform package is refused before anything is opened", () => {
  setHost({ system: "win32", machine: "x64", glibc: false, cpuinfo: "/nonexistent" });
  try {
    assert.equal(
      refused(() => abiVersion(), LibraryLoadError),
      "komira has no native package for win32 x64: its packages are for Linux on x64 and arm64 with glibc, and " +
        "for macOS on arm64",
    );
  } finally {
    resetHost();
    // Every later load of this file reads the planted host, never the real cpuinfo.
    setHost(LINUX_X64);
  }
  assert.equal(addonOpened(), false);
});

test("a CPU the library was not built for is refused before the addon is opened", () => {
  const dir = nativeDir("single", { "libkomira.so": V1 });
  const core2 = fixture("isa_variants/cpuinfo_x86_64_core2.txt");
  const got = refused(() => loadFrom(ADDON_FILE, dir, { ...LINUX_X64, cpuinfo: core2 }), UnsupportedCpuError);
  assert.equal(
    got,
    "libkomira for Linux x64 needs an x86-64-v3 CPU (Haswell or newer); this CPU lacks sse4_2, popcnt, avx, avx2, " +
      `bmi1, bmi2, f16c, fma, abm, movbe (the flags ${core2} lists)`,
  );
  assert.equal(addonOpened(), false);
});

test("a platform package without its addon is refused as damaged", () => {
  const missing = path.join(SCRATCH, "no_addon", "komira_addon.node");
  const dir = nativeDir("for_no_addon", { "libkomira.so": V1 });
  assert.equal(
    refused(() => loadFrom(missing, dir, LINUX_X64), LibraryLoadError),
    `the Node addon ${missing} is missing, so the platform package is damaged: install it again`,
  );
});

test("an addon path under a file, which cannot be read, is refused as missing", () => {
  const file = path.join(SCRATCH, "a_file");
  writeFileSync(file, "");
  const under = path.join(file, "komira_addon.node");
  const dir = nativeDir("for_under_file", { "libkomira.so": V1 });
  assert.equal(
    refused(() => loadFrom(under, dir, LINUX_X64), LibraryLoadError),
    `the Node addon ${under} is missing, so the platform package is damaged: install it again`,
  );
});

test("an addon the loader cannot open is refused with the loader's message", () => {
  const notElf = path.join(SCRATCH, "not_elf", "komira_addon.node");
  mkdirSync(path.dirname(notElf), { recursive: true });
  // Longer than an ELF header, so the loader reads its first bytes.
  writeFileSync(notElf, "not a shared library\n".repeat(8));
  const dir = nativeDir("for_not_elf", { "libkomira.so": V1 });
  assert.equal(
    refused(() => loadFrom(notElf, dir, LINUX_X64), LibraryLoadError),
    `cannot load the Node addon ${notElf}: ${notElf}: invalid ELF header`,
  );
});

test("a native directory without libkomira is refused with the loader's message", () => {
  const empty = path.join(SCRATCH, "empty_native");
  mkdirSync(empty);
  const lib = path.join(empty, "libkomira.so");
  assert.equal(
    refused(() => loadFrom(ADDON_FILE, empty, LINUX_X64), LibraryLoadError),
    `cannot load libkomira from ${lib}: ${lib}: cannot open shared object file: No such file or directory`,
  );
});

test("a library of ABI major 2 is refused with its version", () => {
  const dir = nativeDir("abi2", { "libkomira.so": V2 });
  assert.equal(
    refused(() => loadFrom(ADDON_FILE, dir, LINUX_X64), LibraryLoadError),
    `cannot load libkomira from ${path.join(dir, "libkomira.so")}: libkomira has ABI version 2.0; this addon ` +
      `needs major 1`,
  );
});

test("from a directory of variants the CPU's level is loaded: the x86-64-v3 file, not the floor", () => {
  // The floor is the ABI 2.0 stand-in, which would be refused if it were opened.
  const dir = nativeDir("variants", {
    VARIANTS: fixture("isa_variants/VARIANTS_shipped"),
    "libkomira.so": V2,
    "variants/x86-64-v3/libkomira.so": V1,
  });
  const native = loadFrom(ADDON_FILE, dir, LINUX_X64);
  assert.deepEqual([native.addonFile, native.dir, native.library], [
    ADDON_FILE,
    dir,
    path.join(dir, "variants", "x86-64-v3", "libkomira.so"),
  ]);
  assert.equal(native.addon.abiVersion(), 1001);
});

test("loaded, the same directory is the same library, read again without reading the CPU", () => {
  const first = load();
  const dir = first.dir;
  const relative = path.relative(process.cwd(), dir);
  assert.equal(loadFrom(ADDON_FILE, relative, { ...LINUX_X64, cpuinfo: "/nonexistent" }), first);
  assert.equal(abiVersion(), 1001);
});

test("loaded, another directory is refused naming both", () => {
  const other = nativeDir("other", { "libkomira.so": V1 });
  assert.equal(
    refused(() => loadFrom(ADDON_FILE, other, LINUX_X64), LibraryLoadError),
    `libkomira is already loaded from ${load().dir}, so it cannot be loaded from ${other}`,
  );
});
