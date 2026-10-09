// What the tests share: where the staged files are, the runtime and the
// engine as modules, the shapes and the field numbers of engine_loop.h.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const here = __dirname;

// komira_udf_runtime.h, KOMIRA_UDF_SHAPE_*.
const SHAPE = { SCALAR: 1, ROW: 2, COLUMN: 4, FRAME: 8, FRAME_GROUPED: 16, AGG_PLAIN: 32, AGG_MERGEABLE: 64, STEP: 128 };
// komira_udf_status.
const STATUS = {
  OK: 0, ABI: 1, DESCRIPTOR: 2, UNSUPPORTED: 3, DIGEST: 4, LOAD: 5, RAISED: 6, RETURN_TYPE: 7, LENGTH: 8,
  CANCELLED: 11, DEADLINE: 12, INSTANCE_LOST: 14, INTERNAL: 15, FIELD_NOT_DECLARED: 16,
};
// engine_loop.h: R_* and T_* by name.
const R = {
  STATUS: 0, LOAD_NS: 1, WALL_NS: 2, CPU_USER_NS: 3, CPU_SYS_NS: 4, RSS_BEFORE: 5, RSS_OPEN: 6, CPUS: 7, COLD_NS: 8,
  THREADS: 9, INVOLUNTARY: 10, OPEN_WALL_NS: 11, MEMORY_REPORT: 12, PSS_BEFORE: 13, PSS_OPEN: 14, FIELDS: 15,
};
const T = {
  STATUS: 0, OPEN_CONTEXT_NS: 1, OPEN_INSTANCE_NS: 2, FIRST_CALL_NS: 3, CALLS: 4, ROWS: 5, BAD_VALUES: 6, FIRST_VALUE: 7,
  LAST_VALUE: 8, INCREASING: 9, EXPORTED: 10, RELEASED: 11, WARMUP_CALLS: 12, MEMORY_REPORT: 13, SAMPLES: 14, FIELDS: 15,
};
const CHECK = { NONE: 0, AFFINE: 1, COUNTER: 2, RECORD: 3, NULLS: 4 };

const casesDir = path.join(here, '..', 'src', 'tests', 'helpers', 'komira_udf_spike_abi', 'cases');

const scratch = (name) => fs.mkdtempSync(path.join(os.tmpdir(), `${name}-`));

// A Mojo shared library copied beside a link to the Mojo runtime libraries
// (its run path is $ORIGIN/lib), as a packaged copy would ship them.
function stageMojo(so) {
  const dir = scratch('mojo');
  fs.copyFileSync(path.join(here, so), path.join(dir, so));
  fs.symlinkSync(path.join(here, 'mojo_runtime', 'lib'), path.join(dir, 'lib'));
  return path.join(dir, so);
}

// The runtime addon of a build ('shared' or 'workers') attached to this
// environment as the main one.
function loadRuntime(variant) {
  const file = path.join(here, `runtime_${variant}.node`);
  const addon = require(file);
  const adapter = require('./adapter.js').create(addon, { codeDir: here });
  addon.attachMain(adapter, here, file);
  return { addon, file };
}

const engineHost = () => require(path.join(here, 'engine_host.node'));

// Options of engine.run for a fixture of the bundle.
function opts(entry, shape, extra = {}) {
  return { entry: `fixtures.js#${entry}`, shape, nArgs: 1, argFmt: 'l', resultFmt: 'l', ...extra };
}

// The numbers of a run, by name.
function summary(res) {
  assert.equal(res.run.length, R.FIELDS, 'the run fields differ from engine_loop.h');
  assert.ok(res.threads.length > 0);
  assert.equal(res.threads[0].length, T.FIELDS, 'the thread fields differ from engine_loop.h');
  return res;
}

function median(xs) {
  const s = Array.from(xs).sort((a, b) => a - b);
  return s.length === 0 ? 0 : s[s.length >> 1];
}

// A test that hangs is a failure with a name, not a build action that never
// ends: after `ms` the process exits 2 and says which script it was. The
// message does not say why: a call that never returns, a context that never
// closes and a process that will not exit all end here.
function watchdog(what, ms = 240000) {
  setTimeout(() => {
    console.error(`${what}: no answer after ${ms} ms (a call, a close or the exit did not finish)`);
    process.exit(2);
  }, ms).unref();
}

module.exports = {
  watchdog,
  here, SHAPE, STATUS, R, T, CHECK, casesDir, scratch, stageMojo, loadRuntime, engineHost, opts, summary, median,
};
