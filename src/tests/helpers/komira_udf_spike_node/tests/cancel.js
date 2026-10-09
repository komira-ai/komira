// What cancel can and cannot stop. Argument: the build.
//
// The runtime checks the cancel flag and the deadline between rows (every row
// of a call's first 64, then every 64th) and between batches. A timer thread of
// the engine sets the flag while a call runs:
//   - slow_loop: 20 rows of 100 ms, the flag set after 150 ms: the call ends
//     ERR_CANCELLED at row 2 or 3, about the end of the row in progress
//     (well under the 2 s the call would take);
//   - busy: a row that spins for 300 ms, 3 rows, the flag set after 50 ms:
//     ERR_CANCELLED at row 1, after the 300 ms of the row in progress. Node-API
//     has no call that stops JavaScript running in an isolate, so a row that
//     does not return cannot be interrupted: the stop is at the next row
//     boundary, and a function that never returns is never stopped.
// Both numbers are printed.
//
// A worker_threads isolate can be killed (workers build only): forever, a row
// that never returns, with the flag set after 50 ms: the call ends
// ERR_INSTANCE_LOST once the flag has been set for the 1 s grace period,
// by worker.terminate() (the stop is hard and the context is lost, as the
// design's section 4.7 says), and a call on a new context works. The main
// isolate of the shared build cannot be terminated, so there a row that never
// returns hangs its engine thread: forever is not run on it.
//
// Defects caught: a flag read only before the call; a stop that waits for
// the whole batch; a hard stop that never comes (the call hangs), a lost
// context reused.
//
// Mutants planted: adapter.js's poll() returning null always: red (both calls
// run to the end and answer OK); rt_table.c's ctx_submit never terminating
// (the grace period test `now - seen > ...` made false): the forever call hangs
// and the action's own time limit ends it.
'use strict';

const assert = require('node:assert/strict');
const h = require('./helpers.js');

const variant = process.argv[2];

h.watchdog(`cancel ${variant}`, 120000);

(async () => {
  const { file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  assert.equal(engine.engineInfo(handle).status, 0);
  const probe = (entry, rows, ms) => engine.cancelProbe(handle, { entry: `fixtures.js#${entry}`, shape: h.SHAPE.SCALAR, nArgs: 1, argFmt: 'l', resultFmt: 'l', rows }, ms);

  const slow = await probe('slow_loop', 20, 150);
  console.log(`${variant}: slow_loop cancelled after 150 ms: status ${slow.status} at row ${slow.row}, call took ${(slow.elapsedNs / 1e6).toFixed(0)} ms`);
  assert.equal(slow.status, h.STATUS.CANCELLED, slow.message);
  assert.ok(slow.row >= 1 && slow.row <= 8, `stopped at row ${slow.row}`);
  assert.ok(slow.elapsedNs < 1.5e9, 'the call ran on for the whole batch');

  const busy = await probe('busy', 3, 50);
  console.log(`${variant}: busy cancelled after 50 ms: status ${busy.status} at row ${busy.row}, call took ${(busy.elapsedNs / 1e6).toFixed(0)} ms`);
  assert.equal(busy.status, h.STATUS.CANCELLED, busy.message);
  assert.equal(busy.row, 1, 'the stop is at the next row boundary');
  assert.ok(busy.elapsedNs >= 280e6, `the row in progress was interrupted after ${(busy.elapsedNs / 1e6).toFixed(0)} ms`);

  if (variant === 'workers') {
    const dead = await probe('forever', 3, 50);
    console.log(`workers: forever cancelled after 50 ms: status ${dead.status} (${dead.message}), call took ${(dead.elapsedNs / 1e6).toFixed(0)} ms`);
    assert.equal(dead.status, h.STATUS.INSTANCE_LOST, dead.message);
    assert.ok(dead.elapsedNs >= 1000e6 && dead.elapsedNs < 10e9, `the hard stop took ${(dead.elapsedNs / 1e6).toFixed(0)} ms`);
    const again = await probe('slow_loop', 20, 150);
    assert.equal(again.status, h.STATUS.CANCELLED, `a new context after the lost one: ${again.message}`);
    console.log(`workers: a new context after the lost one: slow_loop cancelled at row ${again.row}`);
  }

  engine.engineClose(handle);
  console.log(`cancel ${variant}: ok`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
