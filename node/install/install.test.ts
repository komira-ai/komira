// @komira-ai/komira as a user installs it. The pinned npm installed the
// tarballs this build wrote into an empty project, offline and with no install
// script run (node/BUCK, :install_test; tools/build/node/defs.bzl,
// npm_install_test), and this file, in that project, imports the package by
// its name: what it loads is what npm laid out under node_modules, and nothing
// of the repository. It runs on each pinned Node.js line.

import assert from "node:assert/strict";
import { readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import * as komira from "@komira-ai/komira";
import * as arrow from "apache-arrow";

/** The project npm installed into: this file's directory. */
const PROJECT = import.meta.dirname;

const MODULES = path.join(PROJECT, "node_modules");

/** The platform package npm chose for this host, Linux on x64 with glibc. */
const PLATFORM = path.join(MODULES, "@komira-ai", "komira-linux-x64-gnu");

/** The package's public names, those exports.test.ts holds for its sources. */
const PUBLIC_NAMES = [
  "KomiraError",
  "LibraryLoadError",
  "Result",
  "Session",
  "UnsupportedCpuError",
  "UnsupportedOperation",
  "abiVersion",
  "registerParquet",
  "sql",
  "version",
];

/** The Mojo runtime libraries the platform package's native directory carries. */
const RUNTIME = ["libAsyncRTRuntimeGlobals.so", "libKGENCompilerRTShared.so", "libMSupportGlobals.so"];

function json(file: string): Record<string, unknown> {
  return JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
}

/** The package-lock.json npm wrote: its packages by their path. */
function lockPackages(): Record<string, Record<string, unknown>> {
  return json(path.join(PROJECT, "package-lock.json"))["packages"] as Record<string, Record<string, unknown>>;
}

/** A Table's rows, each its columns' values in the schema's order. */
function rows(table: arrow.Table): unknown[][] {
  const columns = table.schema.fields.map((f) => [...(table.getChild(f.name) ?? [])]);
  return Array.from({ length: table.numRows }, (_, i) => columns.map((c) => c[i]));
}

test("npm installed the package, the one platform package for this host, and apache-arrow as the peer", () => {
  // The project names the main package alone; npm chose the rest.
  const packages = lockPackages();
  assert.deepEqual(Object.keys(packages[""]?.["dependencies"] as object), ["@komira-ai/komira"]);
  // Of the optionalDependencies, only the package whose os, cpu and libc match.
  assert.deepEqual(readdirSync(path.join(MODULES, "@komira-ai")).sort(), ["komira", "komira-linux-x64-gnu"]);
  const platform = packages["node_modules/@komira-ai/komira-linux-x64-gnu"];
  assert.deepEqual(
    [platform?.["optional"], platform?.["os"], platform?.["cpu"], platform?.["libc"]],
    [true, ["linux"], ["x64"], ["glibc"]],
  );
  // npm installed the peer dependency, which the project does not name.
  const peer = packages["node_modules/apache-arrow"];
  assert.deepEqual([peer?.["version"], peer?.["peer"]], ["21.2.0", true]);
  assert.equal(realpathSync(fileURLToPath(import.meta.resolve("apache-arrow"))).startsWith(realpathSync(MODULES) + path.sep), true);
});

test("the package by its name is the one in node_modules, at its package.json's version, as is its platform package", () => {
  const main = path.join(MODULES, "@komira-ai", "komira");
  assert.equal(realpathSync(fileURLToPath(import.meta.resolve("@komira-ai/komira"))), realpathSync(path.join(main, "dist", "index.js")));
  const version = json(path.join(main, "package.json"))["version"];
  assert.equal(komira.version, version);
  // Unstamped 0.0.0, or a release's 0.1.<N>.
  assert.match(komira.version, /^0\.(0\.0|1\.\d+)$/);
  assert.equal(json(path.join(PLATFORM, "package.json"))["version"], version);
});

test("the package exports exactly its public names", () => {
  assert.deepEqual(Object.keys(komira).sort(), PUBLIC_NAMES);
});

test("the environment holds no Mojo toolchain, and its one library path is node's C++ runtime", () => {
  for (const key of Object.keys(process.env)) {
    assert.doesNotMatch(key, /MOJO|MODULAR|CONDA|PIXI/i, key);
  }
  assert.equal(process.env["LD_PRELOAD"], undefined);
  for (const dir of (process.env["PATH"] ?? "").split(path.delimiter)) {
    assert.doesNotMatch(dir, /mojo|modular/i, dir);
  }
  // The pinned node links libstdc++ and libgcc_s, which a user's system has
  // and the build workers do not: that directory, holding those two alone.
  const libraryPath = (process.env["LD_LIBRARY_PATH"] ?? "").split(path.delimiter);
  assert.equal(libraryPath.length, 1, libraryPath.join(path.delimiter));
  assert.deepEqual(readdirSync(libraryPath[0] as string).sort(), ["libgcc_s.so.1", "libstdc++.so.6"]);
});

test("libkomira, its addon and the Mojo runtime load from the installed platform package and from nowhere else", () => {
  const abi = komira.abiVersion();
  // ABI major 1, the one this package loads.
  assert.equal(Math.floor(abi / 1000), 1, String(abi));
  const report = process.report.getReport() as unknown as { sharedObjects: string[] };
  const ours = report.sharedObjects.filter((f) => ["komira_addon.node", "libkomira.so", ...RUNTIME].includes(path.basename(f)));
  assert.deepEqual([...new Set(ours.map((f) => path.basename(f)))].sort(), ["komira_addon.node", "libkomira.so", ...RUNTIME].sort());
  const platform = realpathSync(PLATFORM) + path.sep;
  const native = realpathSync(path.join(PLATFORM, "native")) + path.sep;
  for (const f of ours) {
    const real = realpathSync(f);
    assert.ok(real.startsWith(path.basename(f) === "komira_addon.node" ? platform : native), real);
  }
});

test("SELECT 1 answers one INT32 row, as a Table of the installed apache-arrow", async () => {
  const s = new komira.Session();
  try {
    const table = await (await s.sql("SELECT 1 AS n")).toArrow();
    assert.ok(table instanceof arrow.Table);
    assert.deepEqual(table.schema.fields.map((f) => f.name), ["n"]);
    assert.ok(table.schema.fields[0]?.type instanceof arrow.Int32);
    assert.deepEqual(rows(table), [[1]]);
    for await (const batch of await s.sql("SELECT 1 AS n")) {
      assert.ok(batch instanceof arrow.RecordBatch);
    }
  } finally {
    await s[Symbol.asyncDispose]();
  }
});

/** The GROUP BY over one source of the eight sales rows. */
function byRegion(from: string): string {
  return `SELECT region, count(*) AS n, min(amount) AS lo, max(amount) AS hi FROM ${from} GROUP BY region ORDER BY region`;
}

/** DuckDB's answer to byRegion over each of the three fixtures, which hold the same rows. */
const BY_REGION = [
  ["east", 3n, 1n, 10n],
  ["north", 2n, 3n, 9n],
  ["west", 3n, 4n, 12n],
];

test("a GROUP BY over the Parquet, CSV and NDJSON fixtures answers as DuckDB does", async () => {
  const fixture = (name: string): string => path.join(PROJECT, "fixtures", name);
  const s = new komira.Session();
  try {
    await s.registerParquet("sales", fixture("sales.parquet"));
    // CSV and NDJSON through the engine's table functions: registerCsv and
    // registerNdjson are not supported yet.
    const sources = ["sales", `read_csv('${fixture("sales.csv")}')`, `read_json('${fixture("sales.ndjson")}')`];
    for (const from of sources) {
      const table = await (await s.sql(byRegion(from))).toArrow();
      assert.deepEqual(table.schema.fields.map((f) => f.name), ["region", "n", "lo", "hi"], from);
      for (const f of table.schema.fields.slice(1)) {
        assert.ok(f.type instanceof arrow.Int64, `${from}: ${f.name} is ${String(f.type)}`);
      }
      assert.deepEqual(rows(table), BY_REGION, from);
    }
  } finally {
    await s[Symbol.asyncDispose]();
  }
});
