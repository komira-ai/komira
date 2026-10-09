// The runtime addon is context-aware: the main thread and four worker_threads,
// alive together, each load it, and each environment has instance data of its
// own (napi_set_instance_data). envCalls() counts per environment: each worker
// sees 1, 2, 3, the main thread's count is not moved by the workers, and a
// worker's state is freed by its finalizer when the worker exits
// (stats().envsFinalized counts the frees). A worker is also not attached
// merely by loading the addon.
//
// Defects caught: state shared between environments (a static counter),
// state never freed, an addon that does not load in a worker, an addon that
// attaches an environment by being loaded.
//
// Mutant planted: envCalls() counting in a process-wide static instead of
// the environment's instance data: red (the workers' counts run on from one
// another).
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

const here = __dirname;
const FILE = path.join(here, 'runtime_workers.node');
const WORKERS = 4;
const CALLS = 3;

if (!isMainThread) {
  const addon = require(FILE);
  const ready = new Int32Array(workerData.ready);
  Atomics.add(ready, 0, 1);
  Atomics.notify(ready, 0);
  // Every worker waits until all have loaded the addon: the environments are
  // alive together.
  while (Atomics.load(ready, 0) < WORKERS) Atomics.wait(ready, 0, Atomics.load(ready, 0), 50);
  const seen = [];
  for (let i = 0; i < CALLS; i++) seen.push(addon.envCalls());
  parentPort.postMessage({ seen, attached: addon.isAttached() });
} else {
  const addon = require(FILE);
  assert.equal(addon.envCalls(), 1);
  assert.equal(addon.isAttached(), false, 'loading the addon attached the environment');
  assert.equal(addon.stats().envsFinalized, 0);
  const ready = new SharedArrayBuffer(4);
  const run = () => new Promise((resolve, reject) => {
    const w = new Worker(__filename, { workerData: { ready } });
    let got = null;
    w.on('message', (m) => { got = m; });
    w.on('error', reject);
    w.on('exit', (code) => (code === 0 ? resolve(got) : reject(new Error(`worker exited ${code}`))));
  });
  Promise.all(Array.from({ length: WORKERS }, run)).then((results) => {
    for (const r of results) {
      assert.deepEqual(r.seen, [1, 2, 3], 'a worker shares instance data with another environment');
      assert.equal(r.attached, false);
    }
    assert.equal(addon.envCalls(), 2, "the workers moved the main thread's count");
    assert.equal(addon.stats().envsFinalized, WORKERS, 'a worker environment exited without its state being freed');
    console.log(`context-aware: workers saw ${JSON.stringify(results.map((r) => r.seen))}, ${addon.stats().envsFinalized} states freed`);
  }).catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
