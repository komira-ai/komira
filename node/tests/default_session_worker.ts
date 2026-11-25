// The worker of default_session.test.ts: it plants the host it is given, makes
// two module-level calls, and posts the addon's session counts.

import { parentPort, workerData } from "node:worker_threads";

import type { Host } from "../src/cpu.ts";
import { registerParquet } from "../src/index.ts";
import { load, setHost } from "../src/native.ts";

const { host, parquet } = workerData as { host: Host; parquet: string };
setHost(host);
await registerParquet("t", parquet);
await registerParquet("u", parquet);
parentPort?.postMessage(load().addon.sessionStats());
