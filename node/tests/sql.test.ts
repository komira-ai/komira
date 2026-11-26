// Session.sql and Result against a stand-in libkomira of ABI 1.9
// (tests/fake_sql.c) whose komira_sql_stream answers fixed queries: a stream
// of two batches, one of no batch, a batch that breaks the C Data Interface, a
// column of a format the package does not map, a get_next that fails, and
// refusals whose code and step the query names. What the real engine answers
// is held by package.test.ts.

import assert from "node:assert/strict";
import { test } from "node:test";

import { Int32, RecordBatch, Table } from "apache-arrow";

import { KomiraError, UnsupportedOperation, type Step } from "../src/errors.ts";
import { Result, sql } from "../src/index.ts";
import { load, loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake, rejected } from "./helpers.ts";

setHost(LINUX_X64);
loadFrom(ADDON_FILE, fake("sql"), LINUX_X64);

/** The stand-in's last error for a query it does not answer (tests/fake_sql.c). */
const FAKE_UNKNOWN_QUERY = "parse: the stand-in answers no such query";

/** The values of the column n of each batch. */
function batchValues(batches: RecordBatch[]): unknown[][] {
  return batches.map((b) => [...(b.getChild("n") ?? [])]);
}

test("toArrow is the whole answer: one Table of the user's apache-arrow, its batches in order", async () => {
  const s = new Session();
  const result = await s.sql("SELECT rows");
  assert.ok(result instanceof Result);
  const table = await result.toArrow();
  assert.ok(table instanceof Table);
  assert.deepEqual(
    table.schema.fields.map((f) => [f.name, String(f.type), f.nullable]),
    [["n", String(new Int32()), true]],
  );
  assert.deepEqual([...(table.getChild("n") ?? [])], [1, 2, 3]);
  assert.deepEqual(batchValues(table.batches), [[1, 2], [3]]);
  await s[Symbol.asyncDispose]();
});

test("for await yields each RecordBatch in order", async () => {
  const s = new Session();
  const batches: RecordBatch[] = [];
  for await (const batch of await s.sql("SELECT rows")) {
    assert.ok(batch instanceof RecordBatch);
    batches.push(batch);
  }
  assert.deepEqual(batchValues(batches), [[1, 2], [3]]);
  await s[Symbol.asyncDispose]();
});

test("a Result is read once: every read after the first rejects, whichever way each reads", async () => {
  const s = new Session();
  const readers: [string, (r: Result) => Promise<unknown>][] = [
    ["toArrow", (r) => r.toArrow()],
    ["iteration", async (r) => {
      for await (const batch of r) void batch;
    }],
  ];
  for (const [first, readFirst] of readers) {
    for (const [second, readSecond] of readers) {
      const result = await s.sql("SELECT rows");
      await readFirst(result);
      assert.equal(await rejected(readSecond(result), KomiraError), "the result was already read", `${first}, ${second}`);
    }
  }
  await s[Symbol.asyncDispose]();
});

test("leaving the loop early ends the read: the Result is not read again", async () => {
  const s = new Session();
  const result = await s.sql("SELECT rows");
  const seen: RecordBatch[] = [];
  for await (const batch of result) {
    seen.push(batch);
    break;
  }
  assert.deepEqual(batchValues(seen), [[1, 2]]);
  assert.equal(await rejected(result.toArrow(), KomiraError), "the result was already read");
  await s[Symbol.asyncDispose]();
});

test("an answer of no batch is an empty Table with its schema, and an iteration of nothing", async () => {
  const s = new Session();
  const table = await (await s.sql("SELECT nothing")).toArrow();
  assert.deepEqual([table.numRows, table.batches.length, table.schema.fields.map((f) => f.name)], [0, 0, ["n"]]);
  const batches: RecordBatch[] = [];
  for await (const batch of await s.sql("SELECT nothing")) batches.push(batch);
  assert.deepEqual(batches, []);
  await s[Symbol.asyncDispose]();
});

test("a Result reads after its session is closed", async () => {
  const s = new Session();
  const result = await s.sql("SELECT rows");
  await s[Symbol.asyncDispose]();
  assert.equal(s.closed, true);
  assert.deepEqual([...((await result.toArrow()).getChild("n") ?? [])], [1, 2, 3]);
});

test("a batch that breaks the C Data Interface rejects the read with a KomiraError naming the column", async () => {
  const s = new Session();
  const message = 'column "n": format "i" has 2 buffers, the array has 1';
  const viaTable = await rejected((await s.sql("SELECT bad batch")).toArrow(), KomiraError);
  assert.equal(viaTable, message);
  const iterate = async (r: Result): Promise<void> => {
    for await (const batch of r) void batch;
  };
  const failed = await iterate(await s.sql("SELECT bad batch")).catch((e: unknown) => e);
  assert.ok(failed instanceof KomiraError);
  assert.deepEqual([failed.constructor, failed.message, failed.status, failed.code], [KomiraError, message, null, null]);
  await s[Symbol.asyncDispose]();
});

test("a column of an Arrow type the package does not read is refused by name, before a batch is read", async () => {
  const s = new Session();
  const message = 'column "n": Arrow format "+w:2" is not supported';
  assert.equal(await rejected((await s.sql("SELECT fixed list")).toArrow(), UnsupportedOperation), message);
  const iterate = async (r: Result): Promise<void> => {
    for await (const batch of r) void batch;
  };
  assert.equal(await rejected(iterate(await s.sql("SELECT fixed list")), UnsupportedOperation), message);
  await s[Symbol.asyncDispose]();
});

test("a stream whose get_next fails rejects sql with the stream's text and no status", async () => {
  const s = new Session();
  const e = await s.sql("SELECT next fails").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.deepEqual(
    [e.constructor, e.message, e.status, e.code, e.step],
    [KomiraError, "get_next failed (status 5): stand-in: the batch cannot be read", null, null, null],
  );
  // The session takes its next query.
  assert.equal((await (await s.sql("SELECT rows")).toArrow()).numRows, 3);
  await s[Symbol.asyncDispose]();
});

test("a refusal carries status -3, the engine's text, and the code and step komira_last_error_code and _step give", async () => {
  const s = new Session();
  const cases: [string, string | null, Step | null][] = [
    ["refuse SQL_SYNTAX_ERROR 1", "SQL_SYNTAX_ERROR", "parse"],
    ["refuse SQL_BIND_ERROR 2", "SQL_BIND_ERROR", "bind"],
    ["refuse OPTIMIZE_UNRESOLVED_SCALAR 3", "OPTIMIZE_UNRESOLVED_SCALAR", "optimize"],
    ["refuse LOWERING_WINDOW_UNSERVED 4", "LOWERING_WINDOW_UNSERVED", "lower"],
    ["refuse MEMORY_BUDGET_EXCEEDED 5", "MEMORY_BUDGET_EXCEEDED", "execute"],
    ["refuse - 5", null, "execute"],
    ["refuse - 0", null, null],
    ["refuse SOME_FUTURE_CODE 9", "SOME_FUTURE_CODE", null],
  ];
  for (const [query, code, step] of cases) {
    const e = await s.sql(query).catch((err: unknown) => err);
    assert.ok(e instanceof KomiraError, query);
    assert.deepEqual([e.constructor, e.message, e.status, e.code, e.step], [KomiraError, query, -3, code, step]);
  }
  const unknown = await s.sql("SELECT 1").catch((err: unknown) => err);
  assert.ok(unknown instanceof KomiraError);
  assert.deepEqual([unknown.message, unknown.status, unknown.code, unknown.step], [FAKE_UNKNOWN_QUERY, -3, null, null]);
  await s[Symbol.asyncDispose]();
});

test("registerParquet's refusal carries the engine's step, and no code when the engine gave none", async () => {
  const s = new Session();
  const e = await s.registerParquet("t", "/nonexistent/t.parquet").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["IO Error: the stand-in has no file", -3, null, "bind"],
  );
  await s[Symbol.asyncDispose]();
});

test("the module-level sql runs on the default session, made at its first call and never closed", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  const before = stats();
  assert.equal((await (await sql("SELECT rows")).toArrow()).numRows, 3);
  const after = stats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [1, 0]);
  assert.equal(await rejected(sql("refuse - 0"), KomiraError), "refuse - 0");
  assert.equal(await rejected(sql(7 as never), TypeError), "the query must be a string");
  assert.deepEqual(stats(), after);
});
