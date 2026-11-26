// The package as npm lays it out: the main package resolves its platform
// package by name, and loads libkomira from the self-contained native
// directory in it (//src/so:libkomira[dist]: the library, its native owners
// and the Mojo runtime libraries) with nothing else on the library path; then
// the real engine registers Parquet files and runs SQL over them. The host is
// planted (Linux x64 with glibc, the x86-64-v3 cpuinfo fixture) so that no
// real /proc/cpuinfo is read.

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import { Int64, Table } from "apache-arrow";

import { KomiraError } from "../src/errors.ts";
import { abiVersion, registerParquet, Session, sql } from "../src/index.ts";
import { load, setHost } from "../src/native.ts";
import { LINUX_X64, PLATFORM_DIR, fixture, scratch } from "./helpers.ts";

setHost(LINUX_X64);

const PARQUET = fixture("two_columns.parquet");

test("the first call loads libkomira from the platform package's native directory", () => {
  // The ABI golden's `version` line (src/so/abi/komira.tsv), major * 1000 + minor.
  const line = readFileSync(fixture("komira.tsv"), "utf8").split("\n")[0] as string;
  const match = /^version\t(\d+)\.(\d+)$/.exec(line);
  assert.ok(match, line);
  assert.equal(abiVersion(), Number(match[1]) * 1000 + Number(match[2]));
  const native = load();
  assert.deepEqual([native.addonFile, native.dir, native.library], [
    path.join(PLATFORM_DIR, "komira_addon.node"),
    path.join(PLATFORM_DIR, "native"),
    path.join(PLATFORM_DIR, "native", "libkomira.so"),
  ]);
});

test("the real library accepts a Parquet file by its path and by its file: URL, and the same name twice", async () => {
  // What each call passes the library is held by register_args.test.ts; here the real engine opens the file.
  const s = new Session();
  await s.registerParquet("t", PARQUET);
  await s.registerParquet("t", pathToFileURL(PARQUET));
  await s.registerParquet("u", PARQUET);
  await s[Symbol.asyncDispose]();
});

test("a relative path is resolved against the working directory when the call is made", async () => {
  const s = new Session();
  const here = process.cwd();
  try {
    process.chdir(path.dirname(PARQUET));
    await s.registerParquet("t", path.basename(PARQUET));
    process.chdir(scratch());
    const e = await s.registerParquet("t", path.basename(PARQUET)).catch((err: unknown) => err);
    assert.ok(e instanceof KomiraError);
    assert.equal(e.status, -3);
  } finally {
    process.chdir(here);
    await s[Symbol.asyncDispose]();
  }
});

test("the engine refusing a missing file is a KomiraError with status -3, step bind, no code, and the engine's text", async () => {
  const s = new Session();
  const missing = path.join(scratch(), "missing.parquet");
  const e = await s.registerParquet("t", missing).catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.equal(e.constructor, KomiraError);
  // The engine reports a registration's failure at the bind step, and an
  // I/O error's text has no code (src/so/README.md).
  assert.deepEqual([e.status, e.code, e.step], [-3, null, "bind"]);
  // The message is the engine's last error, not the addon's wrapper of it.
  assert.ok(e.message.length > 0);
  assert.doesNotMatch(e.message, /komira_register_parquet failed/);
  // The session is still usable after a refusal.
  await s.registerParquet("t", PARQUET);
  await s[Symbol.asyncDispose]();
});

test("the module-level registerParquet uses one default session, made at the first call and never closed", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  const before = stats();
  await registerParquet("t", PARQUET);
  const after = stats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [1, 0]);
  await registerParquet("u", PARQUET);
  assert.deepEqual(stats(), after);
  const e = await registerParquet("t", path.join(scratch(), "missing.parquet")).catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.deepEqual(stats(), after);
});

/**
 * A session with the table `three` registered: a Parquet file of the BIGINT
 * column k holding 1, 2 and 3, which the engine wrote with COPY from a CSV
 * file in a scratch directory. Resolves with the session and COPY's answer.
 */
async function threeRows(): Promise<{ s: Session; copied: Table }> {
  const dir = scratch();
  const csv = path.join(dir, "three.csv");
  const parquet = path.join(dir, "three.parquet");
  writeFileSync(csv, "k\n1\n2\n3\n");
  const s = new Session();
  const copied = await (await s.sql(`COPY (SELECT k FROM read_csv('${csv}')) TO '${parquet}'`)).toArrow();
  await s.registerParquet("three", parquet);
  return { s, copied };
}

test("sql over a registered table answers its rows as an apache-arrow Table", async () => {
  const { s, copied } = await threeRows();
  // COPY answers the BIGINT count of the rows it wrote.
  assert.deepEqual([copied.schema.fields.map((f) => f.name), [...(copied.getChild("Count") ?? [])]], [["Count"], [3n]]);
  const table = await (await s.sql("SELECT k FROM three WHERE k >= 2 ORDER BY k")).toArrow();
  assert.ok(table instanceof Table);
  assert.deepEqual(
    table.schema.fields.map((f) => [f.name, String(f.type)]),
    [["k", String(new Int64())]],
  );
  assert.deepEqual([...(table.getChild("k") ?? [])], [2n, 3n]);
  // The same answer, batch by batch.
  const rows: unknown[] = [];
  for await (const batch of await s.sql("SELECT k FROM three ORDER BY k")) {
    rows.push(...(batch.getChild("k") ?? []));
  }
  assert.deepEqual(rows, [1n, 2n, 3n]);
  await s[Symbol.asyncDispose]();
});

test("a syntax error and an unknown table reject with the engine's text, status -3, code and step", async () => {
  const { s } = await threeRows();
  const syntax = await s.sql("SELEC 1").catch((err: unknown) => err);
  assert.ok(syntax instanceof KomiraError);
  assert.equal(syntax.constructor, KomiraError);
  assert.deepEqual([syntax.status, syntax.code, syntax.step], [-3, "SQL_SYNTAX_ERROR", "parse"]);
  assert.match(syntax.message, /^parse: SQL syntax error: /);
  const unknown = await s.sql("SELECT * FROM nosuch").catch((err: unknown) => err);
  assert.ok(unknown instanceof KomiraError);
  assert.deepEqual(
    [unknown.message, unknown.status, unknown.code, unknown.step],
    ["bind: SQL bind error: unknown table 'nosuch'", -3, "SQL_BIND_ERROR", "bind"],
  );
  // The session takes its next query after a refusal.
  assert.deepEqual([...((await (await s.sql("SELECT count(*) AS n FROM three")).toArrow()).getChild("n") ?? [])], [3n]);
  await s[Symbol.asyncDispose]();
});

test("an answer reads after its session is closed", async () => {
  const { s } = await threeRows();
  const result = await s.sql("SELECT k FROM three ORDER BY k");
  await s[Symbol.asyncDispose]();
  assert.deepEqual([...((await result.toArrow()).getChild("k") ?? [])], [1n, 2n, 3n]);
});

test("the module-level sql runs on the default session", async () => {
  const refused = await sql("SELECT i64, s FROM two_columns").catch((err: unknown) => err);
  // The default session has no table of that name until one is registered on it.
  assert.ok(refused instanceof KomiraError);
  assert.deepEqual([refused.status, refused.code, refused.step], [-3, "SQL_BIND_ERROR", "bind"]);
  await registerParquet("two_columns", PARQUET);
  const empty = await (await sql("SELECT i64, s FROM two_columns")).toArrow();
  assert.deepEqual([empty.numRows, empty.schema.fields.map((f) => f.name)], [0, ["i64", "s"]]);
});
