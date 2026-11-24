// Which libkomira file of a native directory this CPU opens, decided before
// anything is opened (docs/design/isa_variants.md, decision 5; the Python
// loader's `_select_variant` and `_check_cpu` in python/komira/_native.py
// apply the same rules, and both are tested on python/tests/fixtures/isa_variants).
//
// - A directory with a VARIANTS manifest holds libkomira at more than one CPU
//   level. `selectVariant` reads the manifest, reads the CPU's features from
//   the cpuinfo file when a line lists any, and picks the last line, the
//   highest level, whose features the CPU all has. A CPU without the features
//   of the first line, the floor, is an UnsupportedCpuError. A listed file
//   that is missing is a LibraryLoadError, never a load of a lower level in
//   its place.
// - A directory without one holds a single libkomira, built for the platform
//   row's own CPU. `checkCpu` refuses, on Linux x64, a CPU without the flags
//   of x86-64-v3, the level that library is compiled for.

import { lstatSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { LibraryLoadError, UnsupportedCpuError } from "./errors.ts";

/**
 * The host the loader reads: `system` and `machine` as `process.platform`
 * and `process.arch` spell them, whether its C library is glibc, and the
 * file the CPU's features are read from. Tests pass their own.
 */
export interface Host {
  readonly system: string;
  readonly machine: string;
  readonly glibc: boolean;
  readonly cpuinfo: string;
}

/**
 * The CPU flags of x86-64-v3, the level a single linux-x64 libkomira is
 * compiled for, as the `flags` line of Linux's /proc/cpuinfo spells them:
 * x86-64-v2's SSE3 (`pni`), SSSE3, CMPXCHG16B (`cx16`), SSE4.1, SSE4.2, POPCNT
 * and LAHF/SAHF (`lahf_lm`), then x86-64-v3's own AVX, AVX2, BMI1, BMI2, F16C,
 * FMA, LZCNT (`abm`) and MOVBE. A refusal names the missing flags in this
 * order. The same list as `_X86_64_V3_FLAGS` of the Python loader.
 */
export const X86_64_V3_FLAGS: readonly string[] = [
  "pni",
  "ssse3",
  "cx16",
  "sse4_1",
  "sse4_2",
  "popcnt",
  "lahf_lm",
  "avx",
  "avx2",
  "bmi1",
  "bmi2",
  "f16c",
  "fma",
  "abm",
  "movbe",
];

/** The manifest of a directory with more than one CPU level of libkomira. */
export const MANIFEST = "VARIANTS";

/**
 * The cpuinfo key whose words are a processor's features, by machine, on
 * Linux: `flags` on x64, `Features` on arm64.
 */
const FEATURE_KEYS: Readonly<Record<string, string>> = { x64: "flags", arm64: "Features" };

/**
 * The features every processor of cpuinfo `text` lists on its `key` line: a
 * thread may run on any of them. Only that key counts (not `vmx flags`), a
 * feature is a whole word, and no `key` line is no features.
 */
export function cpuFlags(text: string, key: string): Set<string> {
  const processors: Set<string>[] = [];
  for (const line of text.split("\n")) {
    const colon = line.indexOf(":");
    if (colon >= 0 && line.slice(0, colon).trim() === key) {
      processors.push(new Set(line.slice(colon + 1).split(/\s+/).filter((f) => f !== "")));
    }
  }
  const [first, ...rest] = processors;
  if (first === undefined) {
    return new Set();
  }
  return new Set([...first].filter((f) => rest.every((p) => p.has(f))));
}

/**
 * Refuses, before a single libkomira is opened, a CPU it was not built for:
 * on Linux x64, one that lacks a flag of x86-64-v3 is an UnsupportedCpuError
 * naming the flags, and an unreadable cpuinfo is a LibraryLoadError. On any
 * other host nothing is read and nothing is refused.
 */
export function checkCpu(host: Host): void {
  if (host.system !== "linux" || host.machine !== "x64") {
    return;
  }
  let text: string;
  try {
    text = readFileSync(host.cpuinfo, "utf8");
  } catch (e) {
    throw new LibraryLoadError(
      `cannot read the CPU flags from ${host.cpuinfo}, so it is not known whether this CPU implements ` +
        `x86-64-v3, which libkomira for Linux x64 needs: ${(e as Error).message}`,
    );
  }
  const flags = cpuFlags(text, "flags");
  const missing = X86_64_V3_FLAGS.filter((f) => !flags.has(f));
  if (missing.length > 0) {
    throw new UnsupportedCpuError(
      `libkomira for Linux x64 needs an x86-64-v3 CPU (Haswell or newer); this CPU lacks ` +
        `${missing.join(", ")} (the flags ${host.cpuinfo} lists)`,
    );
  }
}

/** One line of a VARIANTS manifest. */
export interface Variant {
  readonly name: string;
  readonly path: string;
  readonly features: readonly string[];
}

/**
 * The lines of `<directory>/VARIANTS`, in the file's order. Each line is
 * three tab-separated fields: the level's name, its file's path inside the
 * directory, and the space-separated features it needs; fields after the
 * third are ignored. A manifest that cannot be read, is not UTF-8, has no
 * line, or has a line without a name, a path inside the directory and a
 * features field is a LibraryLoadError naming the file (and the line).
 */
export function readManifest(directory: string): Variant[] {
  const file = path.join(directory, MANIFEST);
  let data: Buffer;
  try {
    data = readFileSync(file);
  } catch (e) {
    throw new LibraryLoadError(`cannot read the variant manifest ${file}: ${(e as Error).message}`);
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(data);
  } catch {
    throw new LibraryLoadError(`the variant manifest ${file} is not UTF-8`);
  }
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") {
    lines.pop();
  }
  if (lines.length === 0) {
    throw new LibraryLoadError(`the variant manifest ${file} names no variant`);
  }
  return lines.map((line, i) => {
    const [name = "", rel = "", features] = line.split("\t");
    if (name === "" || rel === "" || features === undefined) {
      throw new LibraryLoadError(
        `line ${i + 1} of the variant manifest ${file} is not \`<name><TAB><path><TAB><features>\`: ` +
          JSON.stringify(line),
      );
    }
    if (path.isAbsolute(rel) || rel.split("/").includes("..")) {
      throw new LibraryLoadError(
        `line ${i + 1} of the variant manifest ${file} names ${JSON.stringify(rel)}, ` +
          `which is not a path inside its directory`,
      );
    }
    return { name, path: rel, features: features.split(/\s+/).filter((f) => f !== "") };
  });
}

/**
 * Whether `file` is a file (a link to one included). A path that cannot be
 * read (a file in place of one of its directories, a directory without
 * permission) is not one.
 */
export function isFile(file: string): boolean {
  try {
    return statSync(file).isFile();
  } catch {
    return false;
  }
}

/** Whether anything, a broken link included, is at `file`. */
function lexists(file: string): boolean {
  try {
    lstatSync(file);
    return true;
  } catch {
    return false;
  }
}

/**
 * The absolute path of the variant of libkomira in `directory` that this CPU
 * runs fastest: the last line of its VARIANTS whose features the CPU all has.
 *
 * The CPU's features are read only when a line lists any, from
 * `host.cpuinfo`: the words of the `flags` (x64) or `Features` (arm64) line
 * that every processor lists. Raises LibraryLoadError when the manifest is
 * missing or malformed, when it lists features and the host is not Linux on
 * x64 or arm64, when the cpuinfo cannot be read, and when the picked line's
 * file is missing; raises UnsupportedCpuError, naming the floor and the
 * features of it the CPU lacks, when the CPU has the features of no line.
 */
export function selectVariant(directory: string, host: Host): string {
  const dir = path.resolve(directory);
  const manifest = path.join(dir, MANIFEST);
  const variants = readManifest(dir);
  let have = new Set<string>();
  let key = "";
  if (variants.some((v) => v.features.length > 0)) {
    key = (host.system === "linux" && FEATURE_KEYS[host.machine]) || "";
    if (key === "") {
      throw new LibraryLoadError(
        `the variant manifest ${manifest} lists CPU features, which are read from /proc/cpuinfo only on ` +
          `Linux x64 and arm64, and this is ${host.system} ${host.machine}`,
      );
    }
    let text: string;
    try {
      text = readFileSync(host.cpuinfo, "utf8");
    } catch (e) {
      throw new LibraryLoadError(
        `cannot read the CPU features from ${host.cpuinfo}, so it is not known which variant of libkomira ` +
          `in ${dir} this CPU runs: ${(e as Error).message}`,
      );
    }
    have = cpuFlags(text, key);
  }
  const chosen = variants.filter((v) => v.features.every((f) => have.has(f))).pop();
  if (chosen === undefined) {
    // The floor is variants[0]: readManifest returns at least one line.
    const floor = variants[0] as Variant;
    const missing = floor.features.filter((f) => !have.has(f));
    throw new UnsupportedCpuError(
      `this CPU runs no variant of libkomira in ${dir}: the lowest, ${floor.name}, needs ` +
        `${missing.join(", ")}, which the \`${key}\` lines of ${host.cpuinfo} do not all list`,
    );
  }
  const file = path.join(dir, chosen.path);
  if (!isFile(file)) {
    throw new LibraryLoadError(
      `the variant manifest ${manifest} names ${file} for ${chosen.name}, the variant this CPU runs, and ` +
        `there is no such file; no lower variant is loaded in its place`,
    );
  }
  return file;
}

/** The file name of a single libkomira on `system`. */
export function libraryName(system: string): string {
  return system === "darwin" ? "libkomira.dylib" : "libkomira.so";
}

/**
 * The libkomira file the loader opens from the native directory `directory`
 * (made absolute), once the CPU has been checked: the variant
 * `selectVariant` picks when the directory holds a VARIANTS entry (a broken
 * link or a directory included, which then fails to read), else its single
 * library after `checkCpu`.
 */
export function libraryPath(directory: string, host: Host): string {
  const dir = path.resolve(directory);
  if (lexists(path.join(dir, MANIFEST))) {
    return selectVariant(dir, host);
  }
  checkCpu(host);
  return path.join(dir, libraryName(host.system));
}
