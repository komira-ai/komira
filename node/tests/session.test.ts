// Session against a stand-in libkomira of ABI 1.1 whose
// komira_register_parquet fails with status -3 (KOMIRA_ERR_ENGINE) and the
// last error FAKE_ENGINE_TEXT: an engine refusal is a KomiraError carrying the
// status and the engine's text as its message, with no code and no step,
// which a library older than ABI 1.7 cannot give. Arguments of the wrong type
// or value are TypeError or RangeError, raised before the library is called
// (the stand-in would refuse any call that reached it). Session options need
// ABI 1.4 and `sql` ABI 1.3, so this library refuses them by both versions. The registrations
// this package does not bind yet are refused by name. Closing is idempotent.

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import { KomiraError, UnsupportedOperation } from "../src/errors.ts";
import { load, loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, addonOpened, fake, refused, rejected } from "./helpers.ts";

// Every load of this file reads the planted host, never the real cpuinfo.
setHost(LINUX_X64);

/** The stand-in's last error (node/BUCK, :fake_engine_error). */
const FAKE_ENGINE_TEXT = "IO Error: the stand-in refuses every file";

test("session options: wrong types and values, before the library is loaded", () => {
  const cases: [unknown, ErrorConstructor, string][] = [
    [null, TypeError, "the session options must be an object"],
    [8, TypeError, "the session options must be an object"],
    [[], TypeError, "the session options must be an object"],
    [{ thread: 8 }, TypeError, 'the session options has no option "thread"; its options are threads, memoryLimit'],
    [{ threads: "8" }, TypeError, "threads must be a number"],
    [{ threads: 0 }, RangeError, "threads must be a positive integer, not 0"],
    [{ threads: 1.5 }, RangeError, "threads must be a positive integer, not 1.5"],
    [{ threads: Number.NaN }, RangeError, "threads must be a positive integer, not NaN"],
    [{ memoryLimit: -1 }, RangeError, "memoryLimit must be a positive integer, not -1"],
    [{ memoryLimit: 2 ** 53 }, RangeError, "memoryLimit must be a positive integer, not 9007199254740992"],
    [{ memoryLimit: 1n }, TypeError, "memoryLimit must be a number"],
    [{ memoryLimit: Number.POSITIVE_INFINITY }, RangeError, "memoryLimit must be a positive integer, not Infinity"],
    [{ threads: 8, memoryLimit: 0 }, RangeError, "memoryLimit must be a positive integer, not 0"],
    [{ threads: null }, TypeError, "threads must be a number"],
  ];
  for (const [options, cls, message] of cases) {
    assert.equal(refused(() => new Session(options as never), cls), message, String(options));
  }
  assert.equal(addonOpened(), false);
});

test("the stand-in loads, and an engine refusal carries its status and text, with no code or step before ABI 1.7", async () => {
  const native = loadFrom(ADDON_FILE, fake("engine_error"), LINUX_X64);
  const s = new Session({});
  const before = await s.registerParquet("t", "/nonexistent/t.parquet").catch((e: unknown) => e);
  assert.ok(before instanceof KomiraError);
  assert.equal(before.constructor, KomiraError);
  assert.deepEqual([before.message, before.status, before.code, before.step], [FAKE_ENGINE_TEXT, -3, null, null]);
  // Options left out, or given as undefined, are the engine's defaults.
  new Session({ threads: undefined, memoryLimit: undefined }).close();
  await s[Symbol.asyncDispose]();
  // An option needs komira_ctx_new_with_options, which ABI 1.1 lacks: the
  // refusal names both versions, and no context is made.
  const stats = (): { created: number; freed: number } => native.addon.sessionStats();
  const made = stats().created;
  for (const options of [{ threads: 8 }, { memoryLimit: 1 << 30 }, { threads: 2, memoryLimit: 1 << 20 }]) {
    assert.throws(
      () => new Session(options),
      (e: unknown) => {
        assert.ok(e instanceof KomiraError);
        assert.equal(e.constructor, KomiraError);
        assert.deepEqual(
          [e.message, e.status, e.code, e.step],
          [`komira_ctx_new_with_options needs libkomira ABI version 1.4; the library at ${native.library} is 1.1`, null, null, null],
        );
        return true;
      },
    );
  }
  assert.equal(stats().created, made);
});

test("sql on a library older than ABI 1.3 is refused naming both versions, and the session still works", async () => {
  const native = load();
  const s = new Session();
  const e = await s.sql("SELECT 1").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.deepEqual(
    [e.constructor, e.message, e.status, e.code, e.step],
    [KomiraError, `komira_sql_stream needs libkomira ABI version 1.3; the library at ${native.library} is 1.1`, null, null, null],
  );
  assert.equal(await rejected(s.registerParquet("t", "/nonexistent/t.parquet"), KomiraError), FAKE_ENGINE_TEXT);
  await s[Symbol.asyncDispose]();
});

test("sql: a query that is not a string is a TypeError, and a NUL byte or a lone surrogate a RangeError", async () => {
  const s = new Session();
  const cases: [unknown, ErrorConstructor, string][] = [
    [1, TypeError, "the query must be a string"],
    [undefined, TypeError, "the query must be a string"],
    [Buffer.from("SELECT 1"), TypeError, "the query must be a string"],
    ["SELECT 1\0", RangeError, "the query holds a NUL byte"],
    ["SELECT '\ud800'", RangeError, "the query holds a lone surrogate, which UTF-8 cannot spell"],
  ];
  for (const [query, cls, message] of cases) {
    assert.equal(await rejected(s.sql(query as string), cls), message, message);
  }
  await s[Symbol.asyncDispose]();
});

test("registerParquet: a wrong argument is a TypeError or RangeError, and the library is not called", async () => {
  const s = new Session();
  const cases: [unknown, unknown, ErrorConstructor, string][] = [
    [1, "/x.parquet", TypeError, "the table name must be a string"],
    ["", "/x.parquet", RangeError, "the table name is empty"],
    ["t\0", "/x.parquet", RangeError, "the table name holds a NUL byte"],
    ["t\ud800", "/x.parquet", RangeError, "the table name holds a lone surrogate, which UTF-8 cannot spell"],
    ["t", 1, TypeError, "the path must be a string or a file: URL"],
    ["t", Buffer.from("/x"), TypeError, "the path must be a string or a file: URL"],
    ["t", "", RangeError, "the path is empty"],
    ["t", "/x\0.parquet", RangeError, "the path holds a NUL byte"],
    ["t", "/x\udc00.parquet", RangeError, "the path holds a lone surrogate, which UTF-8 cannot spell"],
    ["t", new URL("file:///x%00.parquet"), RangeError, "the path holds a NUL byte"],
    ["t", new URL("https://example.com/x.parquet"), RangeError, "the path must be a file: URL, not a https: one"],
    [
      "t",
      new URL("file://host.example/x.parquet"),
      RangeError,
      'the path file://host.example/x.parquet is not a file of this host: File URL host must be "localhost" or empty on linux',
    ],
  ];
  for (const [name, file, cls, message] of cases) {
    assert.equal(await rejected(s.registerParquet(name as string, file as string), cls), message, message);
  }
  // A file: URL and a relative path reach the library, which refuses them.
  for (const file of [pathToFileURL("/nonexistent/t.parquet"), "t.parquet", path.join("..", "t.parquet")]) {
    assert.equal(await rejected(s.registerParquet("t", file), KomiraError), FAKE_ENGINE_TEXT);
  }
  await s[Symbol.asyncDispose]();
});

test("registerCsv and registerNdjson check their arguments, then are refused by name", async () => {
  const s = new Session();
  assert.equal(
    await rejected(s.registerCsv("t", "/x.csv"), UnsupportedOperation),
    "registerCsv is not supported yet: this package does not yet bind the call that registers a CSV file by name; registerParquet " +
      "registers a Parquet file",
  );
  assert.equal(
    await rejected(s.registerCsv("t", "/x.csv", { delimiter: "|", header: true, allVarchar: false }), UnsupportedOperation),
    "registerCsv is not supported yet: this package does not yet bind the call that registers a CSV file by name; registerParquet " +
      "registers a Parquet file",
  );
  assert.equal(
    await rejected(s.registerNdjson("t", new URL("file:///x.ndjson")), UnsupportedOperation),
    "registerNdjson is not supported yet: this package does not yet bind the call that registers a newline-delimited JSON file by " +
      "name; registerParquet registers a Parquet file",
  );
  const csv: [unknown[], ErrorConstructor, string][] = [
    [[2, "/x.csv"], TypeError, "the table name must be a string"],
    [["t", 2], TypeError, "the path must be a string or a file: URL"],
    [["t", "/x.csv", "|"], TypeError, "the CSV options must be an object"],
    [["t", "/x.csv", { sep: "|" }], TypeError, 'the CSV options has no option "sep"; its options are delimiter, header, allVarchar'],
    [["t", "/x.csv", { delimiter: 9 }], TypeError, "delimiter must be a string"],
    [["t", "/x.csv", { delimiter: "" }], RangeError, 'delimiter must be one ASCII character other than NUL, not ""'],
    [["t", "/x.csv", { delimiter: ";;" }], RangeError, 'delimiter must be one ASCII character other than NUL, not ";;"'],
    [["t", "/x.csv", { delimiter: "é" }], RangeError, 'delimiter must be one ASCII character other than NUL, not "é"'],
    [["t", "/x.csv", { delimiter: "\0" }], RangeError, 'delimiter must be one ASCII character other than NUL, not "\\u0000"'],
    [["t", "/x.csv", { header: "yes" }], TypeError, "header must be a boolean"],
    [["t", "/x.csv", { allVarchar: 1 }], TypeError, "allVarchar must be a boolean"],
  ];
  for (const [args, cls, message] of csv) {
    const call = s.registerCsv(...(args as [string, string]));
    assert.equal(await rejected(call, cls), message, message);
  }
  assert.equal(await rejected(s.registerNdjson("", "/x.ndjson"), RangeError), "the table name is empty");
  assert.equal(await rejected(s.registerNdjson("t", ""), RangeError), "the path is empty");
  await s[Symbol.asyncDispose]();
});

test("close frees the context once, and a closed session refuses every call", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  const before = stats();
  const s = new Session();
  assert.equal(s.closed, false);
  s.close();
  assert.equal(s.closed, true);
  s.close();
  assert.equal(s.closed, true);
  const after = stats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [1, 1]);
  for (const call of [
    s.registerParquet("t", "/x.parquet"),
    s.registerCsv("t", "/x.csv"),
    s.registerNdjson("t", "/x.ndjson"),
    s.sql("SELECT 1"),
  ]) {
    const e = await call.catch((err: unknown) => err);
    assert.ok(e instanceof KomiraError);
    assert.equal(e.constructor, KomiraError);
    assert.deepEqual([e.message, e.status, e.code], ["the session is closed", null, null]);
  }
  // An argument of the wrong type is still a TypeError on a closed session.
  assert.equal(await rejected(s.registerParquet(1 as never, "/x"), TypeError), "the table name must be a string");
  assert.equal(await rejected(s.sql(1 as never), TypeError), "the query must be a string");
});

test("Symbol.dispose and Symbol.asyncDispose close the session, and so do using and await using", async () => {
  const a = new Session();
  a[Symbol.dispose]();
  assert.equal(a.closed, true);
  const b = new Session();
  await b[Symbol.asyncDispose]();
  assert.equal(b.closed, true);
  let c: Session;
  {
    using s = new Session();
    c = s;
    assert.equal(c.closed, false);
  }
  assert.equal(c.closed, true);
  let d: Session;
  {
    await using s = new Session();
    d = s;
  }
  assert.equal(d.closed, true);
});

test("a call made before close still runs and settles; close refuses later calls at once", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  const s = new Session();
  const before = stats();
  // Queued on the session's thread before close: it runs, and the stand-in refuses it.
  const queued = s.registerParquet("t", "/nonexistent/t.parquet");
  s.close();
  assert.equal(s.closed, true);
  assert.equal(await rejected(s.registerParquet("u", "/nonexistent/u.parquet"), KomiraError), "the session is closed");
  assert.equal(await rejected(queued, KomiraError), FAKE_ENGINE_TEXT);
  // await using settles only once the context is freed, after its calls.
  let pending: Promise<void>;
  {
    await using u = new Session();
    pending = u.registerParquet("t", "/nonexistent/t.parquet");
    pending.catch(() => undefined);
  }
  assert.equal(await rejected(pending, KomiraError), FAKE_ENGINE_TEXT);
  // Disposing s again closes nothing and settles once its context is freed.
  await s[Symbol.asyncDispose]();
  const after = stats();
  assert.equal(after.created - before.created, 1);
  assert.equal(after.freed - before.freed, 2);
});
