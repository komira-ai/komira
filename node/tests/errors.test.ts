// The errors: one base class every deliberate error extends, its fields, and
// how an error the addon throws becomes one. The addon's own codes and the
// KOMIRA_ERR_* names stay private: a failed C call keeps its status, its
// message is the engine's text unchanged, its `code` and `step` are the
// engine's named code and step, and an engine refusal whose code the error
// table gives UnsupportedOperation is one; anything else has no status.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  KomiraError,
  LibraryLoadError,
  UnsupportedCpuError,
  UnsupportedOperation,
  errorClass,
  stepOf,
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
  const engine = new KomiraError("bind: SQL bind error: no table t", { status: -3, code: "SQL_BIND_ERROR", step: "bind" });
  assert.deepEqual(
    [engine.message, engine.status, engine.code, engine.step],
    ["bind: SQL bind error: no table t", -3, "SQL_BIND_ERROR", "bind"],
  );
  const explicitNulls = new KomiraError("x", { status: null, code: null, step: null });
  assert.deepEqual([explicitNulls.status, explicitNulls.code, explicitNulls.step], [null, null, null]);
});

test("stepOf names the five KOMIRA_STEP_* numbers, and is null for none and for anything else", () => {
  assert.deepEqual([1, 2, 3, 4, 5].map(stepOf), ["parse", "bind", "optimize", "lower", "execute"]);
  for (const n of [0, 6, 9, -1, 1.5, Number.NaN, "1", undefined, null]) {
    assert.equal(stepOf(n), null, String(n));
  }
});

test("errorClass: only an engine refusal (-3) with an unsupported-construct code is an UnsupportedOperation", () => {
  assert.equal(errorClass(-3, "SQL_NOT_SUPPORTED"), UnsupportedOperation);
  assert.equal(errorClass(-3, "LOWERING_WINDOW_UNSERVED"), UnsupportedOperation);
  assert.equal(errorClass(-3, "SQL_SYNTAX_ERROR"), KomiraError);
  assert.equal(errorClass(-3, "SOME_FUTURE_CODE"), KomiraError);
  assert.equal(errorClass(-3, null), KomiraError);
  // Another status is never classified by its code.
  for (const status of [-1, -2, -4, -5, -6, -42]) {
    assert.equal(errorClass(status, "SQL_NOT_SUPPORTED"), KomiraError, String(status));
  }
});

/** An error as the addon throws one for a failed C call. */
function addonStatusError(status: number, lastError: string, lastErrorCode = "", lastErrorStep = 0): Error {
  const code = status === -3 ? "KOMIRA_ERR_ENGINE" : "KOMIRA_ERR_UNKNOWN";
  const e = new Error(`komira_register_parquet failed (status ${status})${lastError === "" ? "" : `: ${lastError}`}`);
  return Object.assign(e, { status, code, lastError, lastErrorCode, lastErrorStep });
}

test("a failed C call: its status, the engine's text as the message, and its code and step", () => {
  const e = fromAddon(addonStatusError(-3, "bind: SQL bind error: no table t", "SQL_BIND_ERROR", 2));
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["bind: SQL bind error: no table t", -3, "SQL_BIND_ERROR", "bind"],
  );
});

test("a refusal by an unsupported construct's code is an UnsupportedOperation with its code and step", () => {
  const text = "lower: LOWERING_WINDOW_UNSERVED: no window operator serves RANGE frames";
  const e = fromAddon(addonStatusError(-3, text, "LOWERING_WINDOW_UNSERVED", 4));
  assert.equal(e.constructor, UnsupportedOperation);
  assert.deepEqual([e.message, e.status, e.code, e.step], [text, -3, "LOWERING_WINDOW_UNSERVED", "lower"]);
});

test("an empty code is null, and an unknown step number is null", () => {
  const e = fromAddon(addonStatusError(-3, "IO Error: No files found that match the pattern", "", 9));
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["IO Error: No files found that match the pattern", -3, null, null],
  );
});

test("an addon error without the code and step fields has a null code and step", () => {
  const bare = Object.assign(new Error("komira_register_parquet failed (status -3): x"), {
    status: -3,
    code: "KOMIRA_ERR_ENGINE",
    lastError: "x",
  });
  const e = fromAddon(bare);
  assert.deepEqual([e.message, e.status, e.code, e.step], ["x", -3, null, null]);
  // Fields of the wrong type are no code and no step.
  const wrong = fromAddon(Object.assign(new Error("m"), { status: -3, lastErrorCode: 7, lastErrorStep: "bind" }));
  assert.deepEqual([wrong.message, wrong.status, wrong.code, wrong.step], ["m", -3, null, null]);
});

test("a failed C call with no text keeps the addon's message, and a status other than -3 keeps its code unclassified", () => {
  const e = fromAddon(addonStatusError(-2, ""));
  assert.deepEqual([e.message, e.status, e.code, e.step], ["komira_register_parquet failed (status -2)", -2, null, null]);
  const other = fromAddon(addonStatusError(-5, "too long", "SQL_NOT_SUPPORTED", 1));
  assert.equal(other.constructor, KomiraError);
  assert.deepEqual([other.message, other.status, other.code, other.step], ["too long", -5, "SQL_NOT_SUPPORTED", "parse"]);
});

test("a status the addon has no name for is a KomiraError with that status and no code, never a success", () => {
  const e = fromAddon(addonStatusError(-42, ""));
  assert.deepEqual([e.message, e.status, e.code], ["komira_register_parquet failed (status -42)", -42, null]);
  // A status with no code at all, or a last error that is not a string.
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

test("a stream sql could not drain keeps its message, with no status: its status is the callback's, not the ABI's", () => {
  const raw = Object.assign(new Error("get_next failed (status 5): stand-in"), {
    code: "KOMIRA_ARROW_STREAM",
    status: 5,
    lastError: "stand-in",
  });
  const e = fromAddon(raw);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.message, e.status, e.code, e.step], ["get_next failed (status 5): stand-in", null, null, null]);
});

test("a KomiraError, an UnsupportedOperation of the Arrow import among them, is returned as it is", () => {
  const refused = new UnsupportedOperation('column "n": Arrow format "+w:2" is not supported');
  assert.equal(fromAddon(refused), refused);
  const plain = new KomiraError("the result was already read");
  assert.equal(fromAddon(plain), plain);
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
      throw addonStatusError(-3, "no");
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
