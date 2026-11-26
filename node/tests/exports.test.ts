// The package's public names, exactly, in its TypeScript sources, in the
// JavaScript and declarations tsc compiled from them, imported by the
// package's name through its `exports` map and required from CommonJS; and
// the package.json that npm reads. Importing the package opens nothing.

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { test } from "node:test";

import { PACKAGE, PLATFORM_PACKAGE_NAMES } from "../src/platform.ts";
import { ROOT, addonOpened } from "./helpers.ts";

/** The names a module namespace exports at run time (types have none). */
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

const manifest = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8")) as Record<string, unknown>;

test("the sources export exactly the public names, and importing them opens nothing", async () => {
  const km = await import("../src/index.ts");
  assert.deepEqual(Object.keys(km).sort(), PUBLIC_NAMES);
  assert.equal(addonOpened(), false);
});

test("version is the package.json's", async () => {
  const km = await import("../src/index.ts");
  assert.equal(km.version, manifest["version"]);
  assert.equal(typeof km.version, "string");
});

test("dist holds a .js and a .d.ts for each source, and nothing else", () => {
  const sources = readdirSync(path.join(ROOT, "src")).filter((f) => f.endsWith(".ts"));
  assert.ok(sources.includes("index.ts"));
  const want = sources.flatMap((f) => [f.replace(/\.ts$/, ".d.ts"), f.replace(/\.ts$/, ".js")]).sort();
  assert.deepEqual(readdirSync(path.join(ROOT, "dist")).sort(), want);
});

test("the compiled JavaScript imports its siblings as .js files", () => {
  for (const f of readdirSync(path.join(ROOT, "dist")).filter((f) => f.endsWith(".js"))) {
    const text = readFileSync(path.join(ROOT, "dist", f), "utf8");
    assert.doesNotMatch(text, /from "\.\/[^"]*\.ts"/, `${f} imports a .ts file`);
  }
});

test("the package by its name, through its exports map, is dist/index.js with the same names", async () => {
  const byName = await import(PACKAGE);
  assert.deepEqual(Object.keys(byName).sort(), PUBLIC_NAMES);
  const dist = await import(path.join(ROOT, "dist", "index.js"));
  assert.equal(byName.Session, dist.Session);
  assert.equal(byName.version, manifest["version"]);
});

test("CommonJS requires the package by its name and gets the same module", async () => {
  const required = createRequire(path.join(ROOT, "tests", "commonjs.cjs"))(PACKAGE) as Record<string, unknown>;
  assert.deepEqual(Object.keys(required).sort(), PUBLIC_NAMES);
  const byName = await import(PACKAGE);
  assert.equal(required["Session"], byName.Session);
  assert.equal(addonOpened(), false);
});

test("package.json: an ES module package for Node 22.12 and later, with apache-arrow as its peer", () => {
  assert.equal(manifest["name"], PACKAGE);
  assert.equal(manifest["type"], "module");
  assert.equal(manifest["license"], "Apache-2.0");
  assert.deepEqual(manifest["repository"], {
    type: "git",
    url: "https://github.com/komira-ai/komira",
    directory: "node",
  });
  assert.deepEqual(manifest["engines"], { node: ">=22.12" });
  assert.deepEqual(manifest["peerDependencies"], { "apache-arrow": "^21.2.0" });
  assert.deepEqual(manifest["exports"], {
    ".": { types: "./dist/index.d.ts", default: "./dist/index.js" },
    "./package.json": "./package.json",
  });
  assert.equal(manifest["types"], "./dist/index.d.ts");
  assert.deepEqual(manifest["files"], ["dist/**/*.js", "dist/**/*.d.ts"]);
});

test("package.json: every platform package is an optional dependency at the package's own version", () => {
  const optional = manifest["optionalDependencies"] as Record<string, string>;
  assert.deepEqual(Object.keys(optional).sort(), [...PLATFORM_PACKAGE_NAMES].sort());
  for (const name of PLATFORM_PACKAGE_NAMES) {
    assert.equal(optional[name], manifest["version"], name);
  }
});

test("package.json: unpublishable, with no command, no install script and no dependency of its own", () => {
  assert.equal(manifest["private"], true);
  for (const key of ["bin", "scripts", "dependencies", "devDependencies"]) {
    assert.equal(key in manifest, false, key);
  }
});
