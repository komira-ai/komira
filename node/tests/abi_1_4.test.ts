// A stand-in libkomira of ABI 1.4 (node/BUCK, :fake_v1_4), which has
// komira_ctx_new_with_options and not the 1.7 calls that read a refusal's
// code and step. Session options reach the library; a refusal is a plain
// KomiraError with its status and message, and no code and no step, even when
// the stand-in holds a code that would make it an UnsupportedOperation.

import assert from "node:assert/strict";
import { test } from "node:test";

import { KomiraError } from "../src/errors.ts";
import { loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake, rejected } from "./helpers.ts";

setHost(LINUX_X64);
const native = loadFrom(ADDON_FILE, fake("v1_4"), LINUX_X64);

test("the stand-in is ABI 1.4", () => {
  assert.equal(native.addon.abiVersion(), 1004);
});

test("session options reach komira_ctx_new_with_options on ABI 1.4", async () => {
  await using s = new Session({ threads: 4, memoryLimit: 1 << 26 });
  assert.equal(await rejected(s.registerParquet("ctx", "/x.parquet"), KomiraError), "komira_ctx_new_with_options(4, 67108864)");
});

test("a refusal has no code and no step before ABI 1.7, and is not classified by a code it cannot read", async () => {
  await using s = new Session();
  const e = await s.registerParquet("refuse -3 1 SQL_NOT_SUPPORTED", "/x.parquet").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual(
    [e.message, e.status, e.code, e.step],
    ["stand-in refusal status -3 step 1 code SQL_NOT_SUPPORTED", -3, null, null],
  );
});
