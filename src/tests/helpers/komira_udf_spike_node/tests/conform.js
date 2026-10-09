// The shared conformance suite of komira_udf_spike_abi (the Mojo harness,
// komira_udf_spike_node's node_cases) against the Node runtime, through the C
// ABI only. Argument: the build, 'shared' (every context in the main
// isolate) or 'workers' (one worker_threads isolate per context).
//
// What it proves: every case a TypeScript function can express passes on the
// runtime, none skipped: values, nulls under MANUAL and PROPAGATE, a sliced
// input's offset, a ROW's declared read set (an undeclared read, caught or
// not, fails by name), generators, a plain and a mergeable aggregate, a step,
// an error with its row and message, a result the host must reject, the cancel
// flag set before and during a call, a passed deadline, two contexts giving the
// same answer, validate's refusals. Every array the host exported is
// released once. The describe answer passes the capability checks. The suite
// runs twice: on external buffers over the engine's memory, then on the copy
// path (the design has the conformance harness force it), and the wrap
// counters say which path each pass took.
//
// Defects caught: an offset ignored (values or validity), a null lost, a
// release missing or doubled, cancel or a deadline ignored, a ROW that
// returns null for an undeclared name, an aggregate that overwrites on
// merge, a frame that drains its input before it yields, state shared
// between contexts; a copy path that differs from the zero-copy one, or a
// second pass that silently stays on external buffers.
//
// Mutants planted (adapter.js): vector() not slicing the values to the offset
// (red on sliced_input_offset); rowRecord returning undefined for an
// undeclared name (red on row_undeclared_field and row_caught_violation);
// callRow not checking state.violation (red on row_caught_violation);
// rt_main.c ignoring setCopyMode (the copy pass stays on external buffers: red on the counters); rt_arrow.c copying zeros instead of the bytes (red on the copy pass).
'use strict';

const assert = require('node:assert/strict');
const h = require('./helpers.js');

const variant = process.argv[2];
const EXPECT = {
  shared: { id: 'komira-test/node-shared-isolate', globalLock: 1 },
  workers: { id: 'komira-test/node-workers', globalLock: 0 },
}[variant];
// The corpus's 38 cases less the 8 the Node runtime does not run, plus the
// capabilities check.
const RUN = 30;

h.watchdog(`conform ${variant}`);

(async () => {
  assert.ok(EXPECT, `unknown build ${variant}`);
  const { addon, file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  const info = engine.engineInfo(handle);
  assert.equal(info.status, 0, info.message);
  assert.equal(info.runtimeId, EXPECT.id);
  assert.equal(info.udfClass, 2, 'MANAGED');
  assert.equal(info.hosting, 2, 'HOST_INTERPRETER: node loaded the engine');
  assert.equal(info.threading, 2, 'CONTEXT_PER_THREAD');
  assert.equal(info.globalLock, EXPECT.globalLock);
  assert.equal(info.threadAffine, 0);
  engine.engineClose(handle);

  const so = h.stageMojo('conform_engine.so');
  // The suite on both data paths: external buffers over the engine's memory
  // (the default), then the copy path the design says the conformance harness
  // forces. The wrap counters say which path each pass took.
  const passes = [{ name: 'external buffers', copy: false }, { name: 'copy path', copy: true }];
  for (const pass of passes) {
    addon.setCopyMode(pass.copy);
    const before = addon.stats();
    const res = await engine.conform(so, file, h.casesDir);
    const after = addon.stats();
    console.log(`-- ${pass.name}`);
    console.log(res.report);
    assert.equal(res.rc, 0, `${pass.name}: the suite ran`);
    const m = /^runtime (\S+): (\d+) pass, (\d+) fail, (\d+) skip/.exec(res.report);
    assert.ok(m, `${pass.name}: a report header`);
    assert.equal(m[1], EXPECT.id);
    assert.equal([Number(m[3]), Number(m[4])].join(), '0,0', `${pass.name}: cases failed or skipped`);
    assert.equal(Number(m[2]), RUN + 1, `${pass.name}: every case run and the capabilities check pass`);
    const copies = after.copyWraps - before.copyWraps;
    const externals = after.externalWraps - before.externalWraps;
    if (pass.copy) {
      assert.ok(copies > 0 && externals === 0, `the copy pass copied ${copies} buffers and wrapped ${externals}`);
    } else {
      assert.ok(externals > 0 && copies === 0, `the default pass wrapped ${externals} buffers and copied ${copies}`);
    }
  }
  addon.setCopyMode(false);
  console.log(`conform ${variant}: ok`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
