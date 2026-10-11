// External ArrayBuffers over the engine's memory (design section 5.3,
// "External buffers, with a copy fallback"). Argument: the build.
//
// The V8 rule, probed in child processes (a crash is an exit status, not a
// lost test): what node 24 does when one address is wrapped as two external
// ArrayBuffers (both alive; one detached between; the first dropped and
// garbage collected; an address inside the first). The outcomes are pinned.
// They are the reason the runtime wraps each distinct address once per call
// and detaches every wrap when the call ends.
//
// The runtime, through the engine loop (the runtime's own counters, the
// engine's ledger, the function's own view of its input):
//   - zero copy: every argument buffer is wrapped once per call, and a column
//     used twice in one call (two children over one buffer) is wrapped once,
//     not twice;
//   - the same engine addresses over many calls, one after the other, never
//     abort (a call's wraps are detached, so the next may wrap them again);
//   - a sliced argument (offset 13) is read from its offset, and a null
//     bitmap is wrapped too;
//   - a view the user's code kept is empty once the call has ended (the
//     engine's array is released at return, so the memory behind a kept view
//     is gone: the view must be detached, not dangling);
//   - the copy path (a node built without external buffers, forced here)
//     copies and counts every buffer, gives the same values, and a kept view
//     stays valid (V8 owns the copy);
//   - the result is one copy out of V8, and counted;
//   - every array the engine exported was released by the end of the call,
//     not at a garbage collection.
//
// An argument declaring null_count -1 (unknown) has its nulls counted by the
// runtime from the array's offset: a runtime that took -1 for none would drop
// every null.
//
// The copy mode switched during a call (the automatic fallback does it when a
// Node refuses external buffers) leaves no external wrap of that call
// attached.
//
// Defects caught: a column wrapped twice (the counter doubles, and two
// finalizers would be two releases of one engine array);
// a wrap left attached (a kept view reads memory the engine freed); a buffer
// wrapped past its length; a sliced reader ignoring the offset; an engine
// array held until the finalizer.
//
// Mutants planted (rt_arrow.c): count_nulls reading its bits from 0, not the
// offset: red on the null count of the 1000-row and 3-row slices; `nc = -1` for
// `nc = count_nulls(...)`: red on the wrap count of the all-valid-bitmap run; the
// runtime-file variable left set: red on its assertion. Also: rt_columns_to_js wrapping per child, not per address
// (rt_wrap_buffer without the wrap set): red on the wrap count;
// rt_unwrap_all not detaching: red on the kept view; adapter.js's getter() reading
// a validity bit at the row, not at the offset plus the row: red on the sliced
// null bitmap; rt_columns_to_js taking an unknown null count (-1) for zero:
// red on the unknown-count run (the nulls come back as values); rt_unwrap_all
// deciding by the process-wide copy mode, not the entry's own record: red on
// the switch-during-call run (the detach count falls short of the wraps).
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const h = require('./helpers.js');

const variant = process.argv[2];
const PROBES = path.join(h.here, `runtime_${variant}.node`);

// ---- child: one probe ----------------------------------------------------------
if (process.argv[3] === 'probe') {
  (async () => {
    const addon = require(PROBES);
    const mode = Number(process.argv[4]);
    const out = { mode, statuses: addon.probeWrap(mode) };
    require('node:v8').setFlagsFromString('--expose-gc');
    const gc = require('node:vm').runInNewContext('gc');
    out.finalizedBeforeGc = addon.probeFinalized();
    gc();
    // node runs an ArrayBuffer's finalizer a turn of the event loop after the
    // collection
    await new Promise((resolve) => setTimeout(resolve, 200));
    out.finalizedAfterGc = addon.probeFinalized();
    if (mode === 2) out.statuses3 = addon.probeWrap(3); // wrapped again, the first long collected
    if (mode === 5) {
      // 50 distinct blocks wrapped and dropped: each is finalized (and freed) once
      out.made = addon.probeWrapMany(50, 4096);
      out.refusedBytes = addon.probeWrapMany(3, 0);
      gc();
      await new Promise((resolve) => setTimeout(resolve, 200));
      out.finalizedMany = addon.probeFinalized() - out.finalizedAfterGc;
    }
    console.log(JSON.stringify(out));
    process.exit(0);
  })();
  return;
}

// What node 24.21 does, pinned: none of the four aborts, and every wrap is
// finalized once its ArrayBuffer is collected, so two wraps of one block are
// two finalizers (two releases of the engine's array, if that is what a
// finalizer does).
// The statuses are the Node-API status of each step (0: napi_ok).
const PINNED = {
  0: { status: 0, finalized: 2, statuses: [0, 0] },
  1: { status: 0, finalized: 2, statuses: [0, 0, 0, 0] },
  2: { status: 0, finalized: 1, statuses: [0], statuses3: [0] },
  4: { status: 0, finalized: 2, statuses: [0, 0] },
};

h.watchdog(`external buffers ${variant}`);

(async () => {
  // ---- the V8 rule ----
  const outcome = {};
  for (const mode of [0, 1, 2, 4]) {
    const r = spawnSync(process.execPath, [__filename, variant, 'probe', String(mode)], { env: process.env, encoding: 'utf8', timeout: 60000 });
    let got = {};
    try { got = JSON.parse((r.stdout || '').trim().split('\n').pop()); } catch { /* no answer: the process died */ }
    outcome[mode] = { status: r.status === null ? `signal ${r.signal}` : r.status, finalized: got.finalizedAfterGc, statuses: got.statuses };
    if (mode === 2) outcome[mode].statuses3 = got.statuses3;
    console.log(`probe ${mode}: exit ${outcome[mode].status} ${(r.stdout || '').trim()} ${(r.stderr || '').trim().split('\n')[0] || ''}`);
  }
  {
    const r = spawnSync(process.execPath, [__filename, variant, 'probe', '5'], { env: process.env, encoding: 'utf8', timeout: 60000 });
    const got = JSON.parse((r.stdout || '').trim().split('\n').pop());
    assert.equal(r.status, 0);
    assert.equal(got.made, 50, 'probeWrapMany wraps every block it is asked for');
    assert.equal(got.refusedBytes, undefined, 'probeWrapMany with no bytes is refused (it answers nothing)');
    assert.equal(got.finalizedMany, 50, 'every wrapped block is finalized once after a collection');
    assert.deepEqual(got.statuses, [], 'mode 5 probes no wrap');
  }
  let pinProblem = null;
  try {
    assert.deepEqual(outcome, PINNED, `the V8 wrap rule: ${JSON.stringify(outcome)}, pinned ${JSON.stringify(PINNED)}`);
  } catch (e) {
    pinProblem = e; // raised after the runtime's own checks have run
  }

  // ---- the runtime ----
  const { addon, file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  assert.equal(engine.engineInfo(handle).status, 0);
  const { SHAPE, R, T, CHECK } = h;
  const run = async (o) => {
    const before = addon.stats();
    const r = h.summary(await engine.run(handle, {
      shape: SHAPE.SCALAR, nArgs: 1, argFmt: 'l', resultFmt: 'l', threads: 1, warmupMin: 1, warmupCap: 1, batches: 9, rows: 1000, ...o,
    }));
    assert.equal(r.run[R.STATUS], 0, r.message);
    const after = addon.stats();
    const d = {};
    for (const k of Object.keys(after)) d[k] = after[k] - before[k];
    return { r, d, calls: r.threads[0][T.CALLS] };
  };
  const t0 = (r, f) => r.threads[0][f];

  // zero copy, wrap once
  {
    const { r, d, calls } = await run({ entry: 'fixtures.js#add_strict', nArgs: 2, dupCols: 1, check: CHECK.AFFINE, a: 2, b: 0 });
    assert.equal(t0(r, T.BAD_VALUES), 0);
    assert.equal(d.externalWraps, calls, 'a buffer shared by two children is wrapped once per call');
    assert.equal(d.copyWraps, 0);
    assert.equal(d.detaches, calls, 'every wrap is detached when the call ends');
    assert.equal(d.detachFailures, 0);
    assert.equal(d.wrappedBytes, calls * 1000 * 8);
    assert.equal(t0(r, T.EXPORTED), t0(r, T.RELEASED), 'every exported array was released by the end of the run, not at a collection');
    console.log(`zero copy: ${calls} calls, ${d.externalWraps} external wraps, ${d.wrappedBytes} bytes wrapped, ${d.detaches} detaches`);
  }
  // two separate buffers: two wraps
  {
    const { r, d, calls } = await run({ entry: 'fixtures.js#add_strict', nArgs: 2, dupCols: 0, check: CHECK.AFFINE, a: 2, b: 1 });
    // a + b where b = x + 1: 2x + 1
    assert.equal(t0(r, T.BAD_VALUES), 0);
    assert.equal(d.externalWraps, 2 * calls);
  }
  // sliced, with a null bitmap
  {
    const { r, d, calls } = await run({ entry: 'fixtures.js#double', offset: 13, check: CHECK.AFFINE, a: 2, b: 0 });
    assert.equal(t0(r, T.BAD_VALUES), 0, 'a sliced argument is read from its offset');
    assert.equal(d.externalWraps, calls);
    const nulls = await run({ entry: 'fixtures.js#double', offset: 13, nullEvery: 7, check: CHECK.NULLS, a: 2, b: 0 });
    assert.equal(t0(nulls.r, T.BAD_VALUES), 0, 'a null bitmap sliced at a bit offset (13) is read from it, and the result is null exactly where the input is');
    assert.equal(nulls.d.externalWraps, 2 * nulls.calls, 'the validity bitmap is wrapped beside the values');
    // null_count -1 (unknown) with nulls in a bitmap sliced at bit 13: the runtime counts them itself
    const unknown = await run({ entry: 'fixtures.js#double', offset: 13, nullEvery: 7, nullCountUnknown: 1, check: CHECK.NULLS, a: 2, b: 0 });
    assert.equal(t0(unknown.r, T.BAD_VALUES), 0, 'an argument declaring null_count -1 keeps its nulls: the runtime counts them from the offset');
    assert.equal(unknown.d.externalWraps, 2 * unknown.calls, 'an unknown null count with nulls wraps the bitmap');
    // null_count -1 and no null at all: counted as none, so no bitmap crosses
    const none = await run({ entry: 'fixtures.js#double', offset: 13, nullEvery: 0, nullCountUnknown: 1, check: CHECK.AFFINE, a: 2, b: 0 });
    assert.equal(t0(none.r, T.BAD_VALUES), 0);
    assert.equal(none.d.externalWraps, none.calls, 'an unknown null count over no null is counted as none: the values cross, no bitmap');
    // the same with a validity bitmap present (all rows valid): the runtime counts it, finds none, and sends no bitmap
    const allValid = await run({ entry: 'fixtures.js#double', offset: 13, nullEvery: 0, validBitmap: 1, nullCountUnknown: 1, check: CHECK.AFFINE, a: 2, b: 0 });
    assert.equal(t0(allValid.r, T.BAD_VALUES), 0);
    assert.equal(allValid.d.externalWraps, allValid.calls, 'an unknown null count over an all-valid bitmap is counted as none: no bitmap crosses');
    // The exact count the function sees (it reads the vector's nullCount): of 1000 rows
    // sliced at bit 13 with every 7th null, 143 (a count from bit 0 gives 141); of 3 rows,
    // 1 (a count from bit 0 over bits 0 to 2 gives 0 and the null is lost).
    const colRun = (o) => run({ entry: 'fixtures.js#null_count_of', shape: SHAPE.COLUMN, argFmt: 'l', resultFmt: 'l', offset: 13, nullEvery: 7, nullCountUnknown: 1, check: CHECK.RECORD, batches: 3, ...o });
    const long = await colRun({ rows: 1000 });
    assert.equal(t0(long.r, T.LAST_VALUE), 143, 'the runtime counts the unknown nulls of a 1000-row slice from its offset');
    const short = await colRun({ rows: 3 });
    assert.equal(t0(short.r, T.LAST_VALUE), 1, 'the runtime counts the unknown nulls of a 3-row slice from its offset');
    // the validity bit just past the slice is a null that is not the slice's: it is not counted
    const beyond = await colRun({ rows: 1000, validBitmap: 1, nullBeyond: 1 });
    assert.equal(t0(beyond.r, T.LAST_VALUE), 143, 'a null just past the slice is not counted');
    const beyondNone = await colRun({ rows: 1000, nullEvery: 0, validBitmap: 1, nullBeyond: 1 });
    assert.equal(t0(beyondNone.r, T.LAST_VALUE), 0, 'a null just past an otherwise all-valid slice is not counted');
    // and a known count is passed through as it is
    const known = await colRun({ rows: 1000, nullCountUnknown: 0 });
    assert.equal(t0(known.r, T.LAST_VALUE), 143, 'a declared null count is passed through');
  }
  // a view the user kept
  {
    const { r } = await run({ entry: 'fixtures.js#remember', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g', check: CHECK.RECORD, batches: 3 });
    assert.equal(t0(r, T.FIRST_VALUE), -1, 'the first call kept nothing before it');
    assert.equal(t0(r, T.LAST_VALUE), 0, 'a view kept from an earlier call is empty: its ArrayBuffer was detached');
  }
  // the copy path
  addon.setCopyMode(true);
  {
    const { r, d, calls } = await run({ entry: 'fixtures.js#double', check: CHECK.AFFINE, a: 2, b: 0 });
    assert.equal(t0(r, T.BAD_VALUES), 0, 'the copy path gives the same values');
    assert.equal(d.externalWraps, 0);
    assert.equal(d.copyWraps, calls, 'every buffer is copied, and counted');
    assert.equal(d.detaches, 0, 'a copy belongs to V8 and needs no detach');
    const kept = await run({ entry: 'fixtures.js#remember', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g', check: CHECK.RECORD, batches: 3 });
    assert.equal(t0(kept.r, T.LAST_VALUE), 1000, 'a view kept from a copy stays valid: V8 owns it');
  }
  addon.setCopyMode(false);
  // the copy mode switched in the middle of a call: the wraps already made are still detached
  {
    const prior = process.env.KOMIRA_TEST_RUNTIME_FILE;
    process.env.KOMIRA_TEST_RUNTIME_FILE = file;
    try {
      const { r, d } = await run({ entry: 'fixtures.js#switch_to_copy_path', batches: 3 });
      assert.equal(t0(r, T.BAD_VALUES), 0);
      assert.ok(d.externalWraps >= 1, 'the call that switched the mode was wrapped over the engine memory');
      assert.equal(d.detaches, d.externalWraps, 'every external wrap is detached, though the mode changed during its call');
      assert.equal(d.detachFailures, 0);
    } finally {
      addon.setCopyMode(false);
      if (prior === undefined) delete process.env.KOMIRA_TEST_RUNTIME_FILE;
      else process.env.KOMIRA_TEST_RUNTIME_FILE = prior;
    }
    assert.equal(process.env.KOMIRA_TEST_RUNTIME_FILE, prior, 'the test-only runtime-file variable does not outlive the run that needs it');
  }
  // the result is one copy out
  {
    const { r, d, calls } = await run({ entry: 'fixtures.js#fahrenheit_batch', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g', rows: 1024, check: CHECK.AFFINE, a: 1.8, b: 32 });
    assert.equal(t0(r, T.BAD_VALUES), 0);
    assert.equal(d.outputCopiedBytes, calls * 1024 * 8, 'the result is copied out of V8 once, and counted');
  }
  // a host that breaks the argument contract is refused by name (the engine loop is the host)
  {
    const refused = async (what, badArg, text) => {
      const r = h.summary(await engine.run(handle, {
        shape: SHAPE.SCALAR, nArgs: 1, argFmt: 'l', resultFmt: 'l', threads: 1, warmupMin: 1, warmupCap: 1, batches: 1, rows: 16,
        entry: 'fixtures.js#double', badArg,
      }));
      assert.equal(r.run[R.STATUS], h.STATUS.INTERNAL, `${what}: status ${r.run[R.STATUS]} (${r.message})`);
      assert.ok(r.message.includes(text), `${what}: '${r.message}' lacks '${text}'`);
    };
    await refused('an argument struct at an offset', 1, 'non-zero offset');
    await refused('an extra child', 2, 'different number of children');
    await refused('a child of another length', 3, 'differs in length');
    await refused('a dictionary on a child', 4, 'not a primitive array');
    await refused('three buffers on a child', 5, 'not a primitive array');
  }
  engine.engineClose(handle);
  if (pinProblem !== null) throw pinProblem;
  console.log(`external buffers ${variant}: ok`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
