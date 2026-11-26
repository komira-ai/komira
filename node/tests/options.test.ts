// Session options against a stand-in libkomira of ABI 1.9 (node/BUCK,
// :fake_scripted). Each context it makes holds the call that made it, and
// registering the name "ctx" refuses with that text, so a test reads back
// what reached the library: komira_ctx_new when no option is given, else
// komira_ctx_new_with_options with `threads` and `memoryLimit` as its two
// arguments, 0 for one left out. The stand-in's engine cannot start with 3
// workers, which is how a NULL context is reached. A wrong option is refused
// before the library is called, so no context is made for it.

import assert from "node:assert/strict";
import { test } from "node:test";

import { KomiraError } from "../src/errors.ts";
import { loadFrom, setHost } from "../src/native.ts";
import { Session, type SessionOptions } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake, refused, rejected } from "./helpers.ts";

setHost(LINUX_X64);
const native = loadFrom(ADDON_FILE, fake("scripted"), LINUX_X64);

/** The contexts made and freed so far in this process. */
const stats = (): { created: number; freed: number } => native.addon.sessionStats();

/** The call that made the context of a session with `options`; the session is closed after. */
async function madeBy(options?: SessionOptions): Promise<string> {
  await using s = new Session(options);
  const e = await s.registerParquet("ctx", "/x.parquet").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.status, e.code, e.step], [-3, null, null]);
  return e.message;
}

test("the stand-in is ABI 1.9", () => {
  assert.equal(native.addon.abiVersion(), 1009);
});

test("no option, or every option undefined, makes the context with komira_ctx_new", async () => {
  assert.equal(await madeBy(), "komira_ctx_new()");
  assert.equal(await madeBy({}), "komira_ctx_new()");
  assert.equal(await madeBy({ threads: undefined, memoryLimit: undefined }), "komira_ctx_new()");
});

test("threads and memoryLimit reach komira_ctx_new_with_options as its arguments, and one left out is 0", async () => {
  assert.equal(await madeBy({ threads: 8 }), "komira_ctx_new_with_options(8, 0)");
  assert.equal(await madeBy({ memoryLimit: 1 << 30 }), "komira_ctx_new_with_options(0, 1073741824)");
  assert.equal(await madeBy({ threads: 2, memoryLimit: 1 << 20 }), "komira_ctx_new_with_options(2, 1048576)");
  assert.equal(await madeBy({ threads: 8, memoryLimit: undefined }), "komira_ctx_new_with_options(8, 0)");
  // The smallest and the largest value each option takes.
  assert.equal(await madeBy({ threads: 1, memoryLimit: 1 }), "komira_ctx_new_with_options(1, 1)");
  assert.equal(
    await madeBy({ threads: Number.MAX_SAFE_INTEGER, memoryLimit: Number.MAX_SAFE_INTEGER }),
    "komira_ctx_new_with_options(9007199254740991, 9007199254740991)",
  );
});

test("a session with options frees its context once, as one without does", async () => {
  const before = stats();
  const s = new Session({ threads: 4, memoryLimit: 1 << 20 });
  await s[Symbol.asyncDispose]();
  await s[Symbol.asyncDispose]();
  const after = stats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [1, 1]);
});

test("an engine that cannot start with the options is a KomiraError naming them, and makes no session", () => {
  const before = stats();
  assert.throws(
    () => new Session({ threads: 3, memoryLimit: 4096 }),
    (e: unknown) => {
      assert.ok(e instanceof KomiraError);
      assert.equal(e.constructor, KomiraError);
      assert.deepEqual(
        [e.message, e.status, e.code, e.step],
        ["komira_ctx_new_with_options returned NULL for 3 workers and a budget of 4096 bytes", null, null, null],
      );
      return true;
    },
  );
  assert.equal(stats().created, before.created);
});

test("a wrong option is refused before the library is called, with the library loaded", () => {
  const before = stats();
  const cases: [unknown, ErrorConstructor, string][] = [
    [{ threads: 0 }, RangeError, "threads must be a positive integer, not 0"],
    [{ threads: -8 }, RangeError, "threads must be a positive integer, not -8"],
    [{ threads: 2 ** 53 }, RangeError, "threads must be a positive integer, not 9007199254740992"],
    [{ memoryLimit: 0.5 }, RangeError, "memoryLimit must be a positive integer, not 0.5"],
    [{ threads: "8" }, TypeError, "threads must be a number"],
    [{ memoryLimit: true }, TypeError, "memoryLimit must be a number"],
    [{ threads: 8, caFile: "/ca.pem" }, TypeError, 'the session options has no option "caFile"; its options are threads, memoryLimit'],
  ];
  for (const [options, cls, message] of cases) {
    assert.equal(refused(() => new Session(options as SessionOptions), cls), message, message);
  }
  assert.equal(stats().created, before.created);
});

test("a session of default options runs its calls: a registration the stand-in accepts resolves", async () => {
  await using s = new Session({});
  assert.equal(await s.registerParquet("t", "/x.parquet"), undefined);
  assert.equal(await rejected(s.registerParquet("ctx", "/x.parquet"), KomiraError), "komira_ctx_new()");
});
