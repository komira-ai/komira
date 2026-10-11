// The load gate: the Mojo runtime starts inside a library node's addon loads,
// and works whichever thread calls it. Each case runs in a child node
// process of its own, whose exit status is recorded (a crash is a status,
// not a lost test):
//   main      the call from the main JavaScript thread;
//   pool      the call from a thread node's libuv pool made (the thread the
//             engine runs on in every other test);
//   workers4  the call from 4 worker_threads at once.
// Each must print the expected sum and exit 0, and the outcome of each is
// pinned below: a change either way turns this red.
//
// Defects caught: a library whose Mojo runtime libraries are not found through
// its run path ($ORIGIN/lib); a Mojo runtime that cannot start inside node, or
// that crashes when first entered from a thread it did not create.
//
// Mutant planted: the link to lib/ left out of the scratch directory: red
// (every case exits 1, the library does not load).
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { Worker, isMainThread, workerData, parentPort } = require('node:worker_threads');
const h = require('./helpers.js');

const N = 1000;
const WANT = Array.from({ length: N }, (_, i) => i * i).reduce((a, b) => a + b, 0);
const SYMBOL = 'komira_udf_spike_node_load_gate';
// mode -> the exit status the child must end with.
const PINNED = { main: 0, pool: 0, workers4: 0 };

if (!isMainThread) {
  // A worker: load the engine addon in this environment and call the library.
  const engine = require(path.join(h.here, 'engine_host.node'));
  parentPort.postMessage(engine.gateSync(workerData.so, SYMBOL, N));
} else if (process.argv[2] !== undefined && process.argv[2] !== 'parent') {
  // A child process: one mode.
  const mode = process.argv[2];
  const so = process.argv[3];
  const engine = h.engineHost();
  const check = (got) => {
    assert.equal(got, WANT, `the library returned ${got}`);
    console.log('ok', mode, got);
  };
  if (mode === 'main') {
    check(engine.gateSync(so, SYMBOL, N));
  } else if (mode === 'pool') {
    engine.gateAsync(so, SYMBOL, N).then(check, (e) => { console.error(e); process.exit(1); });
  } else {
    Promise.all([0, 1, 2, 3].map(() => new Promise((resolve, reject) => {
      const w = new Worker(__filename, { workerData: { so } });
      w.on('message', resolve);
      w.on('error', reject);
    }))).then((all) => all.forEach(check), (e) => { console.error(e); process.exit(1); });
  }
} else {
  const so = h.stageMojo('load_gate.so');
  const got = {};
  for (const mode of Object.keys(PINNED)) {
    const r = spawnSync(process.execPath, [__filename, mode, so], { env: process.env, encoding: 'utf8', timeout: 120000 });
    got[mode] = r.status === null ? `signal ${r.signal}` : r.status;
    console.log(mode, 'exit', got[mode], (r.stdout || '').trim(), (r.stderr || '').trim().slice(-400));
  }
  assert.deepEqual(got, PINNED, `exit statuses ${JSON.stringify(got)}, pinned ${JSON.stringify(PINNED)}`);
}
