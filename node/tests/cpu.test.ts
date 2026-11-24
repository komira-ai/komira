// The CPU check of a native directory with a single libkomira: on Linux x64
// the CPU must have every flag of x86-64-v3, the level that library is
// compiled for; the refusal names the flags it lacks. Elsewhere nothing is
// read. And how a cpuinfo's features are read: only the key's own lines, a
// feature as a whole word, the features every processor lists.

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { X86_64_V3_FLAGS, checkCpu, cpuFlags, libraryName, libraryPath, type Host } from "../src/cpu.ts";
import { LibraryLoadError, UnsupportedCpuError } from "../src/errors.ts";
import { V3_CPUINFO, fixture, refused, scratch } from "./helpers.ts";

const SCRATCH = scratch();

function linuxX64(cpuinfo: string): Host {
  return { system: "linux", machine: "x64", glibc: true, cpuinfo };
}

test("cpuFlags: the words every processor lists on the key's lines, and nothing from other lines", () => {
  const text = [
    "processor\t: 0",
    "flags\t\t: a b c d",
    "vmx flags\t: e",
    "processor\t: 1",
    "flags\t\t: b c d e",
    "no colon on this line",
    "Features\t: x",
  ].join("\n");
  assert.deepEqual([...cpuFlags(text, "flags")].sort(), ["b", "c", "d"]);
  assert.deepEqual([...cpuFlags(text, "Features")], ["x"]);
  assert.deepEqual([...cpuFlags(text, "vmx flags")], ["e"]);
  // No line of the key is no features.
  assert.deepEqual([...cpuFlags(text, "bugs")], []);
  assert.deepEqual([...cpuFlags("", "flags")], []);
  // CR LF line ends, and a key with no words.
  assert.deepEqual([...cpuFlags("flags : a b\r\nflags :\r\n", "flags")], []);
  assert.deepEqual([...cpuFlags("flags : a b\r\n", "flags")].sort(), ["a", "b"]);
});

test("the x86-64-v3 flags, in the order a refusal names them", () => {
  assert.deepEqual(X86_64_V3_FLAGS, [
    "pni", "ssse3", "cx16", "sse4_1", "sse4_2", "popcnt", "lahf_lm",
    "avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "abm", "movbe",
  ]);
});

test("an x86-64-v3 CPU passes; one above it passes too", () => {
  checkCpu(linuxX64(V3_CPUINFO));
  checkCpu(linuxX64(fixture("isa_variants/cpuinfo_x86_64_skylake_sp.txt")));
});

test("a CPU below x86-64-v3 is refused naming every flag it lacks, in order", () => {
  const westmere = fixture("isa_variants/cpuinfo_x86_64_westmere.txt");
  assert.equal(
    refused(() => checkCpu(linuxX64(westmere)), UnsupportedCpuError),
    "libkomira for Linux x64 needs an x86-64-v3 CPU (Haswell or newer); this CPU lacks avx, avx2, bmi1, bmi2, f16c, " +
      `fma, abm, movbe (the flags ${westmere} lists)`,
  );
  // One flag missing on one processor of two is missing.
  const v3 = readFileSync(V3_CPUINFO, "utf8");
  const second = v3 +
    "\nprocessor\t: 99\nflags\t\t: pni ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm avx avx2 bmi1 bmi2 f16c fma abm\n";
  const file = path.join(SCRATCH, "one_without_movbe");
  writeFileSync(file, second);
  assert.equal(
    refused(() => checkCpu(linuxX64(file)), UnsupportedCpuError),
    `libkomira for Linux x64 needs an x86-64-v3 CPU (Haswell or newer); this CPU lacks movbe (the flags ${file} lists)`,
  );
});

test("a cpuinfo that cannot be read is a LibraryLoadError, not a claim about the CPU", () => {
  const gone = path.join(SCRATCH, "no_such_cpuinfo");
  assert.equal(
    refused(() => checkCpu(linuxX64(gone)), LibraryLoadError),
    `cannot read the CPU flags from ${gone}, so it is not known whether this CPU implements x86-64-v3, which ` +
      `libkomira for Linux x64 needs: ENOENT: no such file or directory, open '${gone}'`,
  );
});

test("on any host but Linux x64 nothing is read and nothing is refused", () => {
  const gone = path.join(SCRATCH, "no_such_cpuinfo");
  for (const [system, machine] of [
    ["linux", "arm64"],
    ["darwin", "arm64"],
    ["darwin", "x64"],
  ] as const) {
    checkCpu({ system, machine, glibc: false, cpuinfo: gone });
  }
});

test("a directory without a manifest holds a single library, opened after the CPU check", () => {
  const dir = scratch();
  assert.equal(libraryName("linux"), "libkomira.so");
  assert.equal(libraryName("darwin"), "libkomira.dylib");
  assert.equal(libraryPath(dir, linuxX64(V3_CPUINFO)), path.join(dir, "libkomira.so"));
  // A "directory" that is a file has no manifest (ENOTDIR is not one), so its single library is named.
  const file = path.join(SCRATCH, "not_a_dir");
  writeFileSync(file, "");
  assert.equal(libraryPath(file, linuxX64(V3_CPUINFO)), path.join(file, "libkomira.so"));
  const mac: Host = { system: "darwin", machine: "arm64", glibc: false, cpuinfo: path.join(SCRATCH, "gone") };
  assert.equal(libraryPath(dir, mac), path.join(dir, "libkomira.dylib"));
  const core2 = fixture("isa_variants/cpuinfo_x86_64_core2.txt");
  assert.equal(
    refused(() => libraryPath(dir, linuxX64(core2)), UnsupportedCpuError),
    "libkomira for Linux x64 needs an x86-64-v3 CPU (Haswell or newer); this CPU lacks sse4_2, popcnt, avx, avx2, " +
      `bmi1, bmi2, f16c, fma, abm, movbe (the flags ${core2} lists)`,
  );
});
