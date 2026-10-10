// The Node-API addon built by c_shared_lib (BUCK, `addon`) loads in node and
// is context-aware: the main thread and two worker_threads, running at once,
// each load it and each sees its own instance data (count() starts at 1 in
// every environment and the main thread's count is not moved by the workers),
// and each worker's state is freed by its finalizer when the worker exits.
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

const ADDON = path.join(__dirname, 'addon.node');
const CALLS = 3;

if (!isMainThread) {
  const addon = require(ADDON);
  // Every worker waits until both have loaded the addon, so the two
  // environments are alive together.
  const ready = new Int32Array(workerData.ready);
  Atomics.add(ready, 0, 1);
  Atomics.notify(ready, 0);
  while (Atomics.load(ready, 0) < 2) Atomics.wait(ready, 0, Atomics.load(ready, 0), 50);
  const seen = [];
  for (let i = 0; i < CALLS; i++) seen.push(addon.count());
  parentPort.postMessage(seen);
} else {
  const addon = require(ADDON);
  assert.equal(addon.count(), 1);
  assert.equal(addon.finalized(), 0);

  const ready = new SharedArrayBuffer(4);
  const run = () => new Promise((resolve, reject) => {
    const w = new Worker(__filename, { workerData: { ready } });
    let seen = null;
    w.on('message', (m) => { seen = m; });
    w.on('error', reject);
    w.on('exit', (code) => (code === 0 ? resolve(seen) : reject(new Error(`worker exited ${code}`))));
  });

  Promise.all([run(), run()]).then((results) => {
    for (const seen of results) assert.deepEqual(seen, [1, 2, 3], 'a worker shares instance data with another environment');
    assert.equal(addon.count(), 2, "the workers moved the main thread's count");
    assert.equal(addon.finalized(), 2, 'a worker environment exited without its state being freed');
    console.log(`addon: workers saw ${JSON.stringify(results)}, ${addon.finalized()} states freed`);
  }).catch((e) => {
    console.error(e);
    process.exitCode = 1;
  });
}
