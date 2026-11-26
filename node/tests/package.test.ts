// The package as npm lays it out: the main package resolves its platform
// package by name, and loads libkomira from the self-contained native
// directory in it (//src/so:libkomira[dist]: the library, its native owners
// and the Mojo runtime libraries) with nothing else on the library path. The
// host is planted (Linux x64 with glibc, the x86-64-v3 cpuinfo fixture) so
// that no real /proc/cpuinfo is read.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import { KomiraError } from "../src/errors.ts";
import { abiVersion, registerParquet, Session } from "../src/index.ts";
import { load, setHost } from "../src/native.ts";
import { LINUX_X64, PLATFORM_DIR, fixture, scratch } from "./helpers.ts";

setHost(LINUX_X64);

const PARQUET = fixture("two_columns.parquet");

test("the first call loads libkomira from the platform package's native directory", () => {
  // The ABI golden's `version` line (src/so/abi/komira.tsv), major * 1000 + minor.
  const line = readFileSync(fixture("komira.tsv"), "utf8").split("\n")[0] as string;
  const match = /^version\t(\d+)\.(\d+)$/.exec(line);
  assert.ok(match, line);
  assert.equal(abiVersion(), Number(match[1]) * 1000 + Number(match[2]));
  const native = load();
  assert.deepEqual([native.addonFile, native.dir, native.library], [
    path.join(PLATFORM_DIR, "komira_addon.node"),
    path.join(PLATFORM_DIR, "native"),
    path.join(PLATFORM_DIR, "native", "libkomira.so"),
  ]);
});

test("the real library accepts a Parquet file by its path and by its file: URL, and the same name twice", async () => {
  // What each call passes the library is held by register_args.test.ts; here the real engine opens the file.
  const s = new Session();
  await s.registerParquet("t", PARQUET);
  await s.registerParquet("t", pathToFileURL(PARQUET));
  await s.registerParquet("u", PARQUET);
  await s[Symbol.asyncDispose]();
});

test("a relative path is resolved against the working directory when the call is made", async () => {
  const s = new Session();
  const here = process.cwd();
  try {
    process.chdir(path.dirname(PARQUET));
    await s.registerParquet("t", path.basename(PARQUET));
    process.chdir(scratch());
    const e = await s.registerParquet("t", path.basename(PARQUET)).catch((err: unknown) => err);
    assert.ok(e instanceof KomiraError);
    assert.equal(e.status, -3);
  } finally {
    process.chdir(here);
    await s[Symbol.asyncDispose]();
  }
});

test("the engine refusing a missing file is a KomiraError with status -3, its code and the engine's text", async () => {
  const s = new Session();
  const missing = path.join(scratch(), "missing.parquet");
  const e = await s.registerParquet("t", missing).catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.equal(e.constructor, KomiraError);
  assert.deepEqual([e.status, e.code, e.step], [-3, "KOMIRA_ERR_ENGINE", null]);
  // The message is the engine's last error, not the addon's wrapper of it.
  assert.ok(e.message.length > 0);
  assert.doesNotMatch(e.message, /komira_register_parquet failed/);
  // The session is still usable after a refusal.
  await s.registerParquet("t", PARQUET);
  await s[Symbol.asyncDispose]();
});

test("the module-level registerParquet uses one default session, made at the first call and never closed", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  const before = stats();
  await registerParquet("t", PARQUET);
  const after = stats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [1, 0]);
  await registerParquet("u", PARQUET);
  assert.deepEqual(stats(), after);
  const e = await registerParquet("t", path.join(scratch(), "missing.parquet")).catch((err: unknown) => err);
  assert.ok(e instanceof KomiraError);
  assert.deepEqual(stats(), after);
});
