// The errors: one base class every deliberate error extends, its fields, and
// how an error the addon throws becomes one. The addon's own codes stay
// private: a failed C call keeps its status, its message is the engine's text
// unchanged, and its code and step are the engine's (komira_last_error_code
// and _step), null when the library gave none; anything else has no status.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  KomiraError,
  LibraryLoadError,
  UnsupportedCpuError,
  UnsupportedOperation,
  type Step,
} from "../src/errors.ts";
import { call, fromAddon } from "../src/native.ts";
import { packageVersion } from "../src/version.ts";

test("every error is a KomiraError and an Error, named by its class", () => {
  const cases = [
    [new KomiraError("k"), "KomiraError"],
    [new LibraryLoadError("l"), "LibraryLoadError"],
    [new UnsupportedCpuError("c"), "UnsupportedCpuError"],
    [new UnsupportedOperation("u"), "UnsupportedOperation"],
  ] as const;
  for (const [e, name] of cases) {
    assert.ok(e instanceof Error);
    assert.ok(e instanceof KomiraError);
    assert.equal(e.name, name);
    assert.equal(String(e), `${name}: ${e.message}`);
  }
  assert.ok(new UnsupportedCpuError("c") instanceof LibraryLoadError);
  assert.equal(new UnsupportedOperation("u") instanceof LibraryLoadError, false);
});

test("status, code and step are null unless given", () => {
  const plain = new LibraryLoadError("no library");
  assert.deepEqual([plain.message, plain.status, plain.code, plain.step], ["no library", null, null, null]);
  const engine = new KomiraError("Binder Error: no table t", { status: -3, code: "KOMIRA_ERR_ENGINE", step: "bind" });
  assert.deepEqual(
    [engine.message, engine.status, engine.code, engine.step],
    ["Binder Error: no table t", -3, "KOMIRA_ERR_ENGINE", "bind"],
  );
  const explicitNulls = new KomiraError("x", { status: null, code: null, step: null });
  assert.deepEqual([explicitNulls.status, explicitNulls.code, explicitNulls.step], [null, null, null]);
});

/** An error as the addon throws one for a failed C call. */
function addonStatusError(status: number, code: string, lastError: string): Error {
  const e = new Error(`komira_register_parquet failed (status ${status})${lastError === "" ? "" : `: ${lastError}`}`);
  return Object.assign(e, { status, code, lastError });
}

test("a failed C call of a library before ABI 1.7: its status and the engine's text, with no code or step", () => {
  const e = fromAddon(addonStatusError(-3, "KOMIRA_ERR_ENGINE", "IO Error: No files found that match the pattern"));
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["IO Error: No files found that match the pattern", -3, null, null],
  );
});

test("a failed C call of ABI 1.7: the engine's code and the name of each step", () => {
  const steps: [number, Step | null][] = [
    [0, null],
    [1, "parse"],
    [2, "bind"],
    [3, "optimize"],
    [4, "lower"],
    [5, "execute"],
  ];
  for (const [number, name] of steps) {
    const raw = Object.assign(addonStatusError(-3, "KOMIRA_ERR_ENGINE", "parse: SQL syntax error: x"), {
      errorCode: "SQL_SYNTAX_ERROR",
      errorStep: number,
    });
    const e = fromAddon(raw);
    assert.equal(e.constructor, KomiraError);
    assert.deepEqual([e.message, e.status, e.code, e.step], ["parse: SQL syntax error: x", -3, "SQL_SYNTAX_ERROR", name]);
  }
});

test("an empty code is no code, and a step the package does not know is no step", () => {
  const cases: [unknown, unknown, string | null, Step | null][] = [
    ["", 2, null, "bind"],
    ["SOME_FUTURE_CODE", 9, "SOME_FUTURE_CODE", null],
    ["LOWERING_WINDOW_UNSERVED", -1, "LOWERING_WINDOW_UNSERVED", null],
    [7, "2", null, null],
  ];
  for (const [errorCode, errorStep, code, step] of cases) {
    const e = fromAddon(Object.assign(addonStatusError(-3, "KOMIRA_ERR_ENGINE", "t"), { errorCode, errorStep }));
    assert.deepEqual([e.status, e.code, e.step], [-3, code, step], String(errorCode));
  }
});

test("a failed C call with no text keeps the addon's message", () => {
  const e = fromAddon(addonStatusError(-2, "KOMIRA_ERR_NULL_ARG", ""));
  assert.deepEqual([e.message, e.status, e.code], ["komira_register_parquet failed (status -2)", -2, null]);
});

test("a failed callback of an Arrow C stream keeps its message, with no status: its status is not the ABI's", () => {
  const raw = Object.assign(new Error("get_next failed (status 5): stand-in"), {
    code: "KOMIRA_ARROW_STREAM",
    status: 5,
    lastError: "stand-in",
  });
  const e = fromAddon(raw);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.message, e.status, e.code, e.step], ["get_next failed (status 5): stand-in", null, null, null]);
});

test("sql on a library older than ABI 1.3 is a LibraryLoadError with the addon's message", () => {
  const raw = Object.assign(new Error("libkomira has ABI version 1.1; sql needs komira_sql_stream, which ABI 1.3 added"), {
    code: "KOMIRA_ABI_TOO_OLD",
  });
  const e = fromAddon(raw);
  assert.equal(e.constructor, LibraryLoadError);
  assert.deepEqual(
    [e.message, e.status, e.code],
    ["libkomira has ABI version 1.1; sql needs komira_sql_stream, which ABI 1.3 added", null, null],
  );
});

test("a KomiraError, an UnsupportedOperation of the Arrow import among them, is returned as it is", () => {
  const refused = new UnsupportedOperation('column "n": Arrow format "+w:2" is not supported');
  assert.equal(fromAddon(refused), refused);
  const plain = new KomiraError("the result was already read");
  assert.equal(fromAddon(plain), plain);
});

test("a status the addon has no name for is a KomiraError with that status and no code, never a success", () => {
  const e = fromAddon(addonStatusError(-42, "KOMIRA_ERR_UNKNOWN", ""));
  assert.deepEqual([e.message, e.status, e.code], ["komira_register_parquet failed (status -42)", -42, null]);
  // A status with no code at all, or a code that is not a string.
  const bare = fromAddon(Object.assign(new Error("m"), { status: -7, lastError: 3 }));
  assert.deepEqual([bare.message, bare.status, bare.code], ["m", -7, null]);
});

test("the addon refusing its own use has no status and no code", () => {
  const misuse = Object.assign(new TypeError("session must be a value returned by newSession()"), { code: "KOMIRA_ARG" });
  const e = fromAddon(misuse);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.message, e.status, e.code], ["session must be a value returned by newSession()", null, null]);
  // A status that is not a number is not a C call's.
  assert.equal(fromAddon(Object.assign(new Error("s"), { status: "-3" })).status, null);
});

test("a thrown value that is not an Error becomes a KomiraError with its text", () => {
  assert.equal(fromAddon("plain").message, "plain");
  assert.equal(fromAddon(null).message, "null");
  assert.equal(fromAddon(undefined).message, "undefined");
});

test("call returns the call's value and turns what the addon throws into a KomiraError", () => {
  assert.equal(call(() => 7), 7);
  let thrown: unknown;
  try {
    call(() => {
      throw addonStatusError(-3, "KOMIRA_ERR_ENGINE", "no");
    });
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown instanceof KomiraError);
  assert.deepEqual([thrown.message, thrown.status], ["no", -3]);
});

test("the version is read from a package.json, and one without a version string is refused", () => {
  assert.equal(packageVersion({ version: "0.1.7" }), "0.1.7");
  for (const manifest of [{}, { version: 1 }, null, "0.1.7"]) {
    assert.throws(() => packageVersion(manifest), {
      name: "KomiraError",
      message: "the package.json of @komira-ai/komira has no version",
    });
  }
});
