// A status libkomira does not define (the stand-in's komira_register_parquet
// returns -42 and gives no last error) is a KomiraError with that status, no
// code, and the addon's message, never a success.

import assert from "node:assert/strict";
import { test } from "node:test";

import { KomiraError } from "../src/errors.ts";
import { loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake } from "./helpers.ts";

setHost(LINUX_X64);

test("an unknown status rejects with its number and no code", async () => {
  loadFrom(ADDON_FILE, fake("unknown_status"), LINUX_X64);
  const s = new Session();
  const e = await s.registerParquet("t", "/nonexistent/t.parquet").catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.message, e.status, e.code, e.step], ["komira_register_parquet failed (status -42)", -42, null, null]);
  s.close();
});
