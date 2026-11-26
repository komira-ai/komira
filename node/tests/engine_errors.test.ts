// The error table on a stand-in libkomira of ABI 1.9 (node/BUCK,
// :fake_scripted), whose komira_register_parquet answers a table name
// `refuse <status> <step> [<code>]` with that status, KOMIRA_STEP_* number and
// code, and the last error `stand-in refusal status <status> step <step> code
// <code>`. The table is the one the Python package holds
// (docs/design/credentials_and_writes.md, section 11, and
// python/tests/test_errors.py), written out here by its classes. This package
// names only UnsupportedOperation of those classes, so its rows are an
// UnsupportedOperation, and every other row a KomiraError that carries the
// code. Every case checks the whole message, the class exactly, the status,
// the code and the step.

import assert from "node:assert/strict";
import { test } from "node:test";

import { KomiraError, UnsupportedOperation, type Step } from "../src/errors.ts";
import { loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake } from "./helpers.ts";

setHost(LINUX_X64);
loadFrom(ADDON_FILE, fake("scripted"), LINUX_X64);

const NONE = 0;
const PARSE = 1;
const BIND = 2;
const OPTIMIZE = 3;
const LOWER = 4;
const EXECUTE = 5;

const STEP_NAMES: Record<number, Step> = { 1: "parse", 2: "bind", 3: "optimize", 4: "lower", 5: "execute" };

/** The table: the Python package's class name -> its codes. */
const TABLE: Record<string, string[]> = {
  ParseError: ["SQL_SYNTAX_ERROR"],
  BindError: ["SQL_BIND_ERROR", "BIND_NAME_UNBOUND", "BIND_NOT_A_CATALOG", "BIND_SCOPE_NOT_A_TABLE", "BIND_VIEW_NOT_A_QUERY"],
  UnsupportedOperation: [
    "SQL_NOT_SUPPORTED",
    "STATEMENT_NOT_A_QUERY",
    "OPTIMIZE_UNRESOLVED_SCALAR",
    "LOWERING_UNCUTTABLE_NODE",
    "LOWERING_SCAN_NOT_TOTAL",
    "LOWERING_SINK_UNSERVED",
    "LOWERING_JOIN_UNSERVED",
    "LOWERING_WINDOW_UNSERVED",
    "LOWERING_UDF_UNSERVED",
    "SQL_STATEMENT_UNSUPPORTED",
    "COPY_OPTION_UNSUPPORTED",
    "COPY_FORMAT_NOT_INFERRED",
    "STORAGE_URL_REFUSED",
    "STORAGE_RANGE_NOT_SUPPORTED",
    "STORAGE_WRITE_UNSUPPORTED",
    "PLAN_URL_QUERY_REFUSED",
  ],
  MemoryLimitError: ["MEMORY_BUDGET_EXCEEDED"],
  CredentialsError: [
    "CREDENTIAL_UNBOUND",
    "CREDENTIAL_NAME_CONFLICT",
    "CREDENTIAL_KIND_MISMATCH",
    "CREDENTIALS_NOT_FOUND",
    "CREDENTIALS_INVALID",
  ],
  StorageError: [
    "STORAGE_REGION_UNKNOWN",
    "STORAGE_NOT_FOUND",
    "STORAGE_ACCESS_DENIED",
    "STORAGE_THROTTLED",
    "STORAGE_TRANSPORT",
    "STORAGE_MALFORMED",
    "STORAGE_OBJECT_CHANGED",
    "STORAGE_IO",
  ],
};

/** This package's class of a row of the table. */
function nodeClass(row: string): typeof KomiraError {
  return row === "UnsupportedOperation" ? UnsupportedOperation : KomiraError;
}

/**
 * The error the stand-in's refusal with `status`, step number `step` and
 * `code` rejects with, after checking its message and status.
 */
async function refusal(s: Session, status: number, step: number, code = ""): Promise<KomiraError> {
  const name = `refuse ${status} ${step} ${code}`.trimEnd();
  const e = await s.registerParquet(name, "/x.parquet").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError, `${name}: ${String(e)}`);
  assert.equal(e.message, `stand-in refusal status ${status} step ${step} code ${code}`);
  assert.equal(e.status, status);
  return e;
}

test("every code of the table rejects with its class, its code, and no step when it names none", async () => {
  await using s = new Session();
  for (const [row, codes] of Object.entries(TABLE)) {
    for (const code of codes) {
      const e = await refusal(s, -3, NONE, code);
      assert.equal(e.constructor, nodeClass(row), `${code} is a ${e.constructor.name}`);
      assert.deepEqual([e.code, e.step], [code, null], code);
    }
  }
});

test("the code picks the class before the step", async () => {
  await using s = new Session();
  for (const step of [PARSE, BIND]) {
    const e = await refusal(s, -3, step, "SQL_NOT_SUPPORTED");
    assert.equal(e.constructor, UnsupportedOperation);
    assert.deepEqual([e.code, e.step], ["SQL_NOT_SUPPORTED", STEP_NAMES[step]]);
  }
  const e = await refusal(s, -3, LOWER, "SQL_SYNTAX_ERROR");
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.code, e.step], ["SQL_SYNTAX_ERROR", "lower"]);
});

test("the memory budget's refusal carries MEMORY_BUDGET_EXCEEDED and the execute step", async () => {
  await using s = new Session({ memoryLimit: 1 << 20 });
  const e = await refusal(s, -3, EXECUTE, "MEMORY_BUDGET_EXCEEDED");
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.code, e.step], ["MEMORY_BUDGET_EXCEEDED", "execute"]);
});

test("with no code, each step is named and the error is a KomiraError", async () => {
  await using s = new Session();
  for (const step of [PARSE, BIND, OPTIMIZE, LOWER, EXECUTE]) {
    const e = await refusal(s, -3, step);
    assert.equal(e.constructor, KomiraError);
    assert.deepEqual([e.code, e.step], [null, STEP_NAMES[step]]);
  }
  const none = await refusal(s, -3, NONE);
  assert.equal(none.constructor, KomiraError);
  assert.deepEqual([none.code, none.step], [null, null]);
});

test("an unknown code keeps its spelling, and an unknown step number is no step", async () => {
  await using s = new Session();
  const unknownCode = await refusal(s, -3, NONE, "SOME_FUTURE_CODE");
  assert.equal(unknownCode.constructor, KomiraError);
  assert.deepEqual([unknownCode.code, unknownCode.step], ["SOME_FUTURE_CODE", null]);
  const unknownStep = await refusal(s, -3, 9);
  assert.equal(unknownStep.constructor, KomiraError);
  assert.deepEqual([unknownStep.code, unknownStep.step], [null, null]);
  const both = await refusal(s, -3, 9, "STATEMENT_NOT_A_QUERY");
  assert.equal(both.constructor, UnsupportedOperation);
  assert.deepEqual([both.code, both.step], ["STATEMENT_NOT_A_QUERY", null]);
});

test("only an engine refusal is classified; another status keeps its code and step on a KomiraError", async () => {
  await using s = new Session();
  for (const status of [-2, -5]) {
    const e = await refusal(s, status, PARSE, "SQL_NOT_SUPPORTED");
    assert.equal(e.constructor, KomiraError, String(status));
    assert.deepEqual([e.code, e.step], ["SQL_NOT_SUPPORTED", "parse"]);
  }
});

test("a call that succeeds after a refusal resolves, and the session takes further calls", async () => {
  await using s = new Session();
  await refusal(s, -3, BIND, "SQL_BIND_ERROR");
  assert.equal(await s.registerParquet("t", "/x.parquet"), undefined);
  const e = await refusal(s, -3, PARSE, "SQL_SYNTAX_ERROR");
  assert.deepEqual([e.constructor, e.code, e.step], [KomiraError, "SQL_SYNTAX_ERROR", "parse"]);
});
