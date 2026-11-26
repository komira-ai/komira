// The errors: one base class every deliberate error extends, its fields, and
// how an error the addon throws becomes one. The addon's own codes stay
// private: a failed C call keeps its status and its KOMIRA_ERR_* name, and
// its message is the engine's text unchanged; anything else has no status.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  KomiraError,
  LibraryLoadError,
  UnsupportedCpuError,
  UnsupportedOperation,
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

test("a failed C call: its status and code, and the engine's text as the message", () => {
  const e = fromAddon(addonStatusError(-3, "KOMIRA_ERR_ENGINE", "IO Error: No files found that match the pattern"));
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["IO Error: No files found that match the pattern", -3, "KOMIRA_ERR_ENGINE", null],
  );
});

test("a failed C call with no text keeps the addon's message", () => {
  const e = fromAddon(addonStatusError(-2, "KOMIRA_ERR_NULL_ARG", ""));
  assert.deepEqual([e.message, e.status, e.code], ["komira_register_parquet failed (status -2)", -2, "KOMIRA_ERR_NULL_ARG"]);
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
