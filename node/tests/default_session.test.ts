// The default session is per JavaScript environment: a worker thread makes its
// own at its first module-level call, because an addon external cannot cross
// environments, and the main thread's is untouched. sessionStats counts the
// contexts the addon made in the whole process.

import assert from "node:assert/strict";
import { once } from "node:events";
import { test } from "node:test";
import { Worker } from "node:worker_threads";

import { registerParquet } from "../src/index.ts";
import { load, setHost } from "../src/native.ts";
import { LINUX_X64, fixture } from "./helpers.ts";

setHost(LINUX_X64);

const PARQUET = fixture("two_columns.parquet");

test("a worker thread has a default session of its own, and the main thread keeps its one", async () => {
  const stats = (): { created: number; freed: number } => load().addon.sessionStats();
  await registerParquet("t", PARQUET);
  const main = stats();
  const worker = new Worker(new URL("./default_session_worker.ts", import.meta.url), {
    workerData: { host: LINUX_X64, parquet: PARQUET },
  });
  const [reply] = (await once(worker, "message")) as [{ created: number; freed: number }];
  await once(worker, "exit");
  // The worker made one context for its two calls; the main thread none.
  assert.deepEqual([reply.created - main.created, reply.freed - main.freed], [1, 0]);
  await registerParquet("u", PARQUET);
  assert.equal(stats().created, reply.created);
});
