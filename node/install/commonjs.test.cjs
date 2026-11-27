// @komira-ai/komira required from CommonJS, in the project npm installed it
// into (install.test.ts says how): Node's require() of an ES module, which
// the package's engines floor, Node 22.12, has without a flag, gives a `.cjs`
// file its public names and the engine. Its own process, so this require() is
// the first load of the package and of libkomira.
"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");

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

test("require() of the package by its name gives its public names, and its Session runs SQL", async () => {
  const komira = require("@komira-ai/komira");
  assert.deepEqual(Object.keys(komira).sort(), PUBLIC_NAMES);
  assert.equal(komira.version, require("@komira-ai/komira/package.json").version);
  const s = new komira.Session();
  try {
    const table = await (await s.sql("SELECT 1 AS n")).toArrow();
    assert.deepEqual([...(table.getChild("n") ?? [])], [1]);
  } finally {
    await s[Symbol.asyncDispose]();
  }
});
