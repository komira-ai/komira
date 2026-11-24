// The variant selector: from a directory with a VARIANTS manifest, the loader
// opens the highest CPU level whose features every processor of the cpuinfo
// lists, falls back to a lower level only when the CPU lacks a feature of the
// higher one, refuses a CPU below the lowest with UnsupportedCpuError, and
// refuses a damaged directory with LibraryLoadError instead of loading another
// level (docs/design/isa_variants.md, decision 5). The fixtures and the table
// of expected choices are the Python selector's (python/tests/fixtures/isa_variants),
// so the two loaders cannot disagree; the shipped manifest is the one the
// build writes from the linux-x86_64 row.

import assert from "node:assert/strict";
import { mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { X86_64_V3_FLAGS, libraryPath, selectVariant, type Host } from "../src/cpu.ts";
import { LibraryLoadError, UnsupportedCpuError } from "../src/errors.ts";
import { V3_CPUINFO, fixture, refused, scratch } from "./helpers.ts";

const SCRATCH = scratch();

/** A fixture by the name the table gives it. */
function cpuinfoFixture(name: string): string {
  return name === "cpuinfo_x86_64_v3.txt" ? V3_CPUINFO : fixture(path.join("isa_variants", name));
}

function read(file: string): string {
  return readFileSync(file, "utf8");
}

function write(file: string, content: string | Buffer): string {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, content);
  return file;
}

/**
 * A directory `name` with `manifest` as its VARIANTS and an empty file at each
 * path a line names, or at `files` instead.
 */
function nativeDirWith(name: string, manifest: string | Buffer, files?: string[]): string {
  const d = path.join(SCRATCH, name);
  write(path.join(d, "VARIANTS"), manifest);
  const paths = files ?? manifest.toString().split("\n").filter((l) => l !== "").map((l) => l.split("\t")[1] as string);
  for (const rel of paths) {
    write(path.join(d, rel), "");
  }
  return d;
}

/** `content` with the words `drop` taken off the `key` line of every processor, or of the `processor`-th (from 0). */
function without(content: string, drop: string[], processor?: number, key = "flags"): string {
  let seen = -1;
  return content
    .split("\n")
    .map((line) => {
      const colon = line.indexOf(":");
      if (colon < 0 || line.slice(0, colon).trim() !== key) {
        return line;
      }
      seen += 1;
      if (processor !== undefined && processor !== seen) {
        return line;
      }
      const words = line.slice(colon + 1).split(/\s+/).filter((w) => w !== "" && !drop.includes(w));
      return `${line.slice(0, colon)}: ${words.join(" ")}`;
    })
    .join("\n");
}

function linux(machine: string, cpuinfo: string): Host {
  return { system: "linux", machine, glibc: true, cpuinfo };
}

function x64(directory: string, cpuinfo: string): string {
  return selectVariant(directory, linux("x64", cpuinfo));
}

function unsupported(directory: string, floor: string, missing: string[], cpuinfo: string, key = "flags"): string {
  return (
    `this CPU runs no variant of libkomira in ${directory}: the lowest, ${floor}, needs ${missing.join(", ")}, ` +
    `which the \`${key}\` lines of ${cpuinfo} do not all list`
  );
}

// The manifests by the names the table gives them, each in a directory of its own.
const MANIFESTS: Record<string, string> = {
  shipped: read(fixture("isa_variants/VARIANTS_shipped")),
  VARIANTS_x86_64_v4: read(fixture("isa_variants/VARIANTS_x86_64_v4")),
  VARIANTS_aarch64: read(fixture("isa_variants/VARIANTS_aarch64")),
  VARIANTS_macos: read(fixture("isa_variants/VARIANTS_macos")),
};
const DIRS: Record<string, string> = Object.fromEntries(
  Object.entries(MANIFESTS).map(([name, text]) => [name, nativeDirWith(`m_${name}`, text)]),
);

function lines(name: string): string[][] {
  return (MANIFESTS[name] as string).split("\n").filter((l) => l !== "").map((l) => l.split("\t"));
}

const SHIPPED = lines("shipped");
const V3_ONLY = ((SHIPPED[1] as string[])[2] as string)
  .split(" ")
  .filter((f) => !((SHIPPED[0] as string[])[2] as string).split(" ").includes(f))
  .sort();

test("the shipped manifest: the x86-64-v2 floor at libkomira.so, and x86-64-v3 with the single library's flags", () => {
  assert.deepEqual(
    SHIPPED.map((l) => l.slice(0, 2)),
    [
      ["x86-64-v2", "libkomira.so"],
      ["x86-64-v3", "variants/x86-64-v3/libkomira.so"],
    ],
  );
  assert.deepEqual(((SHIPPED[1] as string[])[2] as string).split(" ").sort(), [...X86_64_V3_FLAGS].sort());
  assert.deepEqual(V3_ONLY, ["abm", "avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "movbe"]);
});

/** process.arch's spelling of the table's machine, which is platform.machine()'s. */
const ARCH: Record<string, string> = { x86_64: "x64", aarch64: "arm64", arm64: "arm64" };
const KEY: Record<string, string> = { x64: "flags", arm64: "Features" };

test("the table of expected choices, shared with the Python loader", () => {
  const rows = read(fixture("isa_variants/choices.tsv"))
    .split("\n")
    .filter((l) => l !== "")
    .map((l) => l.split("\t"));
  assert.deepEqual(rows[0], ["cpuinfo", "system", "machine", "manifest", "choice"]);
  assert.ok(rows.length > 1);
  for (const [cpuinfoName, system, machine, manifest, choice] of rows.slice(1) as string[][]) {
    const directory = DIRS[manifest as string] as string;
    const names = new Map(lines(manifest as string).map((l) => [path.join(directory, l[1] as string), l[0]]));
    const cpuinfo = cpuinfoFixture(cpuinfoName as string);
    const h: Host = { system: system as string, machine: ARCH[machine as string] as string, glibc: true, cpuinfo };
    const where = `${cpuinfoName} ${manifest}`;
    if ((choice as string).startsWith("refused ")) {
      const floor = (lines(manifest as string)[0] as string[])[0] as string;
      const want = unsupported(directory, floor, (choice as string).split(" ").slice(1), cpuinfo, KEY[h.machine]);
      assert.equal(refused(() => selectVariant(directory, h), UnsupportedCpuError), want, where);
    } else {
      assert.equal(names.get(selectVariant(directory, h)), choice, where);
    }
  }
});

test("from the x86-64-v3 CPU, lacking any feature only x86-64-v3 needs gives x86-64-v2", () => {
  const v3 = read(V3_CPUINFO);
  const dir = DIRS["shipped"] as string;
  const floor = path.join(dir, "libkomira.so");
  assert.equal(x64(dir, V3_CPUINFO), path.join(dir, "variants", "x86-64-v3", "libkomira.so"));
  for (const flag of V3_ONLY) {
    const one = write(path.join(SCRATCH, `v3_without_${flag}`), without(v3, [flag]));
    assert.equal(x64(dir, one), floor, flag);
  }
  // A feature counts only when every processor lists it.
  const second = write(path.join(SCRATCH, "avx2_on_one"), without(v3, ["avx2"], 1));
  assert.equal(x64(dir, second), floor);
  // Only the `flags` key counts: avx2 on the `vmx flags` line alone does not.
  const vmxText = without(v3, ["avx2"]).replace("vmx flags\t: ", "vmx flags\t: avx2 ");
  assert.ok(vmxText.includes("vmx flags\t: avx2 "));
  assert.equal(x64(dir, write(path.join(SCRATCH, "avx2_on_vmx"), vmxText)), floor);
  // A feature is a whole word: avx2x does not give avx2.
  const word = without(v3, ["avx2"]).replace(" avx ", " avx avx2x ");
  assert.ok(word.includes(" avx2x "));
  assert.equal(x64(dir, write(path.join(SCRATCH, "avx2_as_part"), word)), floor);
  // Without a floor feature too, the CPU is refused, naming only the floor's missing ones.
  const low = write(path.join(SCRATCH, "no_popcnt"), without(v3, ["popcnt", "avx2"]));
  assert.equal(refused(() => x64(dir, low), UnsupportedCpuError), unsupported(dir, "x86-64-v2", ["popcnt"], low));
});

test("on arm64, neoverse-n1 without atomics on one processor gets generic, and without fp is refused", () => {
  const n1 = read(cpuinfoFixture("cpuinfo_aarch64_neoverse_n1.txt"));
  const dir = DIRS["VARIANTS_aarch64"] as string;
  const noAtomics = write(path.join(SCRATCH, "n1_without_atomics"), without(n1, ["atomics"], 2, "Features"));
  assert.equal(selectVariant(dir, linux("arm64", noAtomics)), path.join(dir, "libkomira.so"));
  const noFp = write(path.join(SCRATCH, "n1_without_fp"), without(n1, ["fp"], undefined, "Features"));
  assert.equal(
    refused(() => selectVariant(dir, linux("arm64", noFp)), UnsupportedCpuError),
    unsupported(dir, "generic", ["fp"], noFp, "Features"),
  );
});

test("the manifest is read as written: the last line the CPU satisfies, extra fields, no final newline, CR LF", () => {
  const order = nativeDirWith("order", "low\tlow.so\t\nhigh\thigh.so\tavx2\n");
  assert.equal(x64(order, V3_CPUINFO), path.join(order, "high.so"));
  const extra = nativeDirWith("extra", "x86-64-v2\tlibkomira.so\tpni\tsize=1\tmore\n");
  assert.equal(x64(extra, V3_CPUINFO), path.join(extra, "libkomira.so"));
  const noNewline = nativeDirWith("no_newline", "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\tv3.so\tavx2");
  assert.equal(x64(noNewline, V3_CPUINFO), path.join(noNewline, "v3.so"));
  const crlf = nativeDirWith("crlf", "x86-64-v2\tlibkomira.so\tpni\r\nx86-64-v3\tv3.so\tavx2\r\n", [
    "libkomira.so",
    "v3.so",
  ]);
  assert.equal(x64(crlf, V3_CPUINFO), path.join(crlf, "v3.so"));
});

test("a relative directory is made absolute against the working directory", () => {
  const dir = DIRS["shipped"] as string;
  const here = process.cwd();
  process.chdir(dir);
  try {
    assert.equal(x64(".", V3_CPUINFO), path.join(dir, "variants", "x86-64-v3", "libkomira.so"));
    assert.equal(libraryPath(".", linux("x64", V3_CPUINFO)), path.join(dir, "variants", "x86-64-v3", "libkomira.so"));
  } finally {
    process.chdir(here);
  }
});

test("with no line listing features nothing is read, on any host", () => {
  const gone = path.join(SCRATCH, "no_such_cpuinfo");
  const dir = DIRS["VARIANTS_macos"] as string;
  for (const [system, machine] of [
    ["darwin", "arm64"],
    ["linux", "x64"],
    ["linux", "riscv64"],
  ] as const) {
    assert.equal(selectVariant(dir, { system, machine, glibc: false, cpuinfo: gone }), path.join(dir, "libkomira.dylib"));
  }
});

test("a cpuinfo that cannot be read is a LibraryLoadError, not a claim about the CPU", () => {
  const gone = path.join(SCRATCH, "no_such_cpuinfo");
  const dir = DIRS["shipped"] as string;
  assert.equal(
    refused(() => x64(dir, gone), LibraryLoadError),
    `cannot read the CPU features from ${gone}, so it is not known which variant of libkomira in ${dir} this CPU ` +
      `runs: ENOENT: no such file or directory, open '${gone}'`,
  );
});

test("features are read only on Linux x64 and arm64", () => {
  const dir = DIRS["shipped"] as string;
  for (const [system, machine] of [
    ["darwin", "arm64"],
    ["darwin", "x64"],
    ["linux", "riscv64"],
    ["win32", "x64"],
  ] as const) {
    const got = refused(() => selectVariant(dir, { system, machine, glibc: true, cpuinfo: V3_CPUINFO }), LibraryLoadError);
    assert.equal(
      got,
      `the variant manifest ${path.join(dir, "VARIANTS")} lists CPU features, which are read from /proc/cpuinfo ` +
        `only on Linux x64 and arm64, and this is ${system} ${machine}`,
    );
  }
});

test("a missing manifest names the file", () => {
  const bare = path.join(SCRATCH, "bare");
  mkdirSync(bare);
  const m = path.join(bare, "VARIANTS");
  assert.equal(
    refused(() => x64(bare, V3_CPUINFO), LibraryLoadError),
    `cannot read the variant manifest ${m}: ENOENT: no such file or directory, open '${m}'`,
  );
});

/** The refusal of a directory whose VARIANTS is `manifest` (and no other file). */
function manifestRefusal(name: string, manifest: string | Buffer): [string, string] {
  const d = nativeDirWith(name, manifest, []);
  return [path.join(d, "VARIANTS"), refused(() => x64(d, V3_CPUINFO), LibraryLoadError)];
}

test("a manifest that is not UTF-8, or names no variant, is refused naming it", () => {
  const [latin1, got] = manifestRefusal("latin1", Buffer.from("x86-64-v2\tlibkomira.so\tpni \xff\n", "latin1"));
  assert.equal(got, `the variant manifest ${latin1} is not UTF-8`);
  const [empty, none] = manifestRefusal("empty", "");
  assert.equal(none, `the variant manifest ${empty} names no variant`);
});

test("a line without a name, a path and a features field is refused naming the line", () => {
  const cases: [string, string, number, string][] = [
    ["two_fields", "x86-64-v2\tlibkomira.so\n", 1, "x86-64-v2\tlibkomira.so"],
    ["spaces", "x86-64-v2 libkomira.so pni\n", 1, "x86-64-v2 libkomira.so pni"],
    ["no_name", "\tlibkomira.so\tpni\n", 1, "\tlibkomira.so\tpni"],
    ["no_path", "x86-64-v2\t\tpni\n", 1, "x86-64-v2\t\tpni"],
    ["blank", "x86-64-v2\tlibkomira.so\tpni\n\nx86-64-v3\tv3.so\tavx2\n", 2, ""],
    ["newline", "\n", 1, ""],
    ["second", "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\n", 2, "x86-64-v3"],
  ];
  for (const [name, text, number, line] of cases) {
    const [m, got] = manifestRefusal(name, text);
    assert.equal(
      got,
      `line ${number} of the variant manifest ${m} is not \`<name><TAB><path><TAB><features>\`: ${JSON.stringify(line)}`,
      name,
    );
  }
});

test("a path outside the directory, absolute or through .., is refused", () => {
  for (const [name, rel] of [
    ["absolute", "/lib/libkomira.so"],
    ["dotdot", "variants/../../libkomira.so"],
    ["up", ".."],
  ] as const) {
    const [m, got] = manifestRefusal(name, `x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\t${rel}\tavx2\n`);
    assert.equal(
      got,
      `line 2 of the variant manifest ${m} names ${JSON.stringify(rel)}, which is not a path inside its directory`,
      name,
    );
  }
});

test("the picked file missing is refused naming it, and the floor is not loaded in its place", () => {
  const shipped = MANIFESTS["shipped"] as string;
  const want = (d: string): string =>
    `the variant manifest ${path.join(d, "VARIANTS")} names ${path.join(d, "variants", "x86-64-v3", "libkomira.so")} ` +
    `for x86-64-v3, the variant this CPU runs, and there is no such file; no lower variant is loaded in its place`;
  const noV3 = nativeDirWith("no_v3", shipped, ["libkomira.so"]);
  assert.equal(refused(() => x64(noV3, V3_CPUINFO), LibraryLoadError), want(noV3));
  // A missing file of a level the CPU does not run is not looked at.
  assert.equal(x64(noV3, cpuinfoFixture("cpuinfo_x86_64_westmere.txt")), path.join(noV3, "libkomira.so"));
  // A path through a file (ENOTDIR) is no file either, not an error of its own.
  const throughFile = nativeDirWith("through_file", "x86-64-v2\tlibkomira.so\tpni\nx86-64-v3\tlibkomira.so/v3\tavx2\n", [
    "libkomira.so",
  ]);
  assert.equal(
    refused(() => x64(throughFile, V3_CPUINFO), LibraryLoadError),
    `the variant manifest ${path.join(throughFile, "VARIANTS")} names ${path.join(throughFile, "libkomira.so", "v3")} ` +
      `for x86-64-v3, the variant this CPU runs, and there is no such file; no lower variant is loaded in its place`,
  );
  // A directory at the picked path is not a library file either.
  const dirV3 = nativeDirWith("dir_v3", shipped, ["libkomira.so", "variants/x86-64-v3/libkomira.so/x"]);
  assert.equal(refused(() => x64(dirV3, V3_CPUINFO), LibraryLoadError), want(dirV3));
});

test("a VARIANTS that is a directory or a link to nothing still makes the directory one of variants", () => {
  const asDir = path.join(SCRATCH, "variants_is_dir");
  mkdirSync(path.join(asDir, "VARIANTS"), { recursive: true });
  write(path.join(asDir, "libkomira.so"), "");
  assert.equal(
    refused(() => libraryPath(asDir, linux("x64", V3_CPUINFO)), LibraryLoadError),
    `cannot read the variant manifest ${path.join(asDir, "VARIANTS")}: EISDIR: illegal operation on a directory, read`,
  );
  const dangling = path.join(SCRATCH, "variants_dangling");
  mkdirSync(dangling);
  write(path.join(dangling, "libkomira.so"), "");
  const m = path.join(dangling, "VARIANTS");
  symlinkSync(path.join(dangling, "gone"), m);
  assert.equal(
    refused(() => libraryPath(dangling, linux("x64", V3_CPUINFO)), LibraryLoadError),
    `cannot read the variant manifest ${m}: ENOENT: no such file or directory, open '${m}'`,
  );
});

test("a directory with a manifest picks its variant without the single library's CPU check", () => {
  // The CPU is below x86-64-v3, which the single library's check refuses, and
  // the manifest's floor runs on it.
  const dir = DIRS["shipped"] as string;
  const westmere = cpuinfoFixture("cpuinfo_x86_64_westmere.txt");
  assert.equal(libraryPath(dir, linux("x64", westmere)), path.join(dir, "libkomira.so"));
});
