// What reaches komira_register_parquet: against a stand-in whose last error
// is the name and path the C call received (node/BUCK, :fake_echo_register),
// each call's refusal reads back its own arguments. The table name is passed
// unchanged, under the name of this call and not an earlier one, and the path
// is the absolute file: a string as given, a file: URL as its path, and a
// relative path resolved against the working directory at the call.

import assert from "node:assert/strict";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import { KomiraError } from "../src/errors.ts";
import { registerParquet } from "../src/index.ts";
import { loadFrom, setHost } from "../src/native.ts";
import { Session } from "../src/session.ts";
import { ADDON_FILE, LINUX_X64, fake, rejected, scratch } from "./helpers.ts";

setHost(LINUX_X64);
loadFrom(ADDON_FILE, fake("echo_register"), LINUX_X64);

/** The name and path the C call received, read from its refusal. */
async function received(call: Promise<void>): Promise<string[]> {
  return (await rejected(call, KomiraError)).split("\t");
}

test("each call passes its own table name and the absolute path it was given", async () => {
  const s = new Session();
  const file = path.join(scratch(), "trips.parquet");
  assert.deepEqual(await received(s.registerParquet("t", file)), ["t", file]);
  // A second name on the same session is that call's, not the first's.
  assert.deepEqual(await received(s.registerParquet("u", file)), ["u", file]);
  // Names are passed as written: case, spaces, dots and non-ASCII kept.
  assert.deepEqual(await received(s.registerParquet("Trips 2.é", file)), ["Trips 2.é", file]);
  s.close();
});

test("a file: URL is passed as its path, decoded", async () => {
  const s = new Session();
  const file = path.join(scratch(), "a b%.parquet");
  assert.deepEqual(await received(s.registerParquet("t", pathToFileURL(file))), ["t", file]);
  assert.deepEqual(await received(s.registerParquet("u", new URL("file:///x/a%20b.parquet"))), ["u", "/x/a b.parquet"]);
  s.close();
});

test("a relative path is resolved against the working directory when the call is made", async () => {
  const s = new Session();
  const first = scratch();
  const second = scratch();
  mkdirSync(path.join(second, "sub"));
  const here = process.cwd();
  try {
    process.chdir(first);
    assert.deepEqual(await received(s.registerParquet("t", "trips.parquet")), ["t", path.join(first, "trips.parquet")]);
    process.chdir(path.join(second, "sub"));
    assert.deepEqual(await received(s.registerParquet("t", "trips.parquet")), [
      "t",
      path.join(second, "sub", "trips.parquet"),
    ]);
    assert.deepEqual(await received(s.registerParquet("t", "../x/./y.parquet")), [
      "t",
      path.join(second, "x", "y.parquet"),
    ]);
    // `~` is not expanded: it is a directory name like any other.
    assert.deepEqual(await received(s.registerParquet("t", "~/y.parquet")), [
      "t",
      path.join(second, "sub", "~", "y.parquet"),
    ]);
  } finally {
    process.chdir(here);
    s.close();
  }
});

test("the module-level registerParquet passes the same arguments through the default session", async () => {
  const file = path.join(scratch(), "d.parquet");
  assert.deepEqual(await received(registerParquet("d", file)), ["d", file]);
});
