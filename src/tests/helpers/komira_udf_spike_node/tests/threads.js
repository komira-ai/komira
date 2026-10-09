// N engine threads through the runtime, each with a context and an instance
// of its own (engine_loop.c on four pthreads). Argument: the build.
//
// What it proves, for both builds: every value is right on every thread; the
// runtime is entered once per batch (its call counter equals the batches the
// threads made: no per-row hop); every array the engine exported is released;
// state is per context (a module-level counter starts at 1 on every thread:
// each context evaluates the bundle afresh, in the shared isolate too);
// outputs held past the close of their context are whole when read and
// released; each context runs on a worker thread of its own (workers) or on the
// main thread (shared); memory_report reports the model each context holds
// (16 MiB per context);
// and a call made on the environment's own JavaScript thread is refused, not
// deadlocked.
//
// The parallelism case: four threads each spin for 200 ms of CPU inside user
// code. With one isolate per context (workers) the process uses CPU time of
// at least 0.6 x min(4, CPUs) x wall; with every context in the one isolate
// (shared) it stays at about 1 x wall (at most 1.3): the isolate's thread is
// a lock shared across engine threads, which the baseline declares
// (global_lock 1). A farm worker is shared, so a ratio is marked noisy when it
// is under 0.8 x the threads the CPUs allow.
//
// Defects caught: a shared interpreter behind per-thread contexts (the
// counter would run on across threads), a lock across engine threads in the
// build that declares none, a per-row hop, an array not released, a call on
// the wrong thread.
//
// Mutants planted: adapter.js sharing one module instance across contexts
// (ctx.modules replaced by a process-wide map): red (a counter past K);
// rt_table.c's call_batch behind one process-wide mutex, in the workers build:
// red (CPU/wall 1.00 under the 2.4 it needs); the workers build placing every
// context on the main environment: red (the process aborts when the contexts
// close).
'use strict';

const assert = require('node:assert/strict');
const h = require('./helpers.js');

const variant = process.argv[2];
const N = 4;

h.watchdog(`threads ${variant}`);

(async () => {
  const { addon, file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  const info = engine.engineInfo(handle);
  assert.equal(info.status, 0, info.message);
  const { SHAPE, R, T, CHECK, STATUS } = h;
  const run = async (o) => {
    const before = addon.stats();
    const r = h.summary(await engine.run(handle, {
      shape: SHAPE.SCALAR, nArgs: 1, argFmt: 'l', resultFmt: 'l', threads: N, warmupMin: 8, warmupCap: 8, batches: 20, rows: 1024, ...o,
    }));
    const after = addon.stats();
    return { r, calls: after.calls - before.calls, requests: after.requests - before.requests };
  };

  // values, calls == batches, releases
  {
    const { r, calls } = await run({ entry: 'fixtures.js#fahrenheit_rows', argFmt: 'g', resultFmt: 'g', check: CHECK.AFFINE, a: 1.8, b: 32 });
    assert.equal(r.run[R.STATUS], 0, r.message);
    let total = 0;
    for (const t of r.threads) {
      assert.equal(t[T.STATUS], 0);
      assert.equal(t[T.BAD_VALUES], 0, 'a wrong value');
      assert.equal(t[T.EXPORTED], t[T.RELEASED], 'an exported array was not released');
      assert.equal(t[T.ROWS], t[T.CALLS] * 1024);
      total += t[T.CALLS];
    }
    assert.equal(calls, total, 'the runtime was entered other than once per batch');
    console.log(`${variant}: ${N} threads, ${total} batches of 1024 rows, ${calls} runtime calls`);
  }
  // outputs the engine holds past the close of their context and the unload
  // of their UDF are still whole, and are released (it checks them then)
  {
    const { r } = await run({ entry: 'fixtures.js#fahrenheit_rows', argFmt: 'g', resultFmt: 'g', check: CHECK.AFFINE, a: 1.8, b: 32, hold: 1, threads: 2 });
    assert.equal(r.run[R.STATUS], 0, r.message);
    for (const t of r.threads) assert.equal(t[T.BAD_VALUES], 0, 'an output read after its context closed was wrong');
  }
  // which isolate runs each context
  {
    const { r } = await run({ entry: 'fixtures.js#thread_id', check: CHECK.RECORD, rows: 4, batches: 2, warmupMin: 1, warmupCap: 1 });
    assert.equal(r.run[R.STATUS], 0, r.message);
    const ids = r.threads.map((t) => t[T.LAST_VALUE]);
    if (variant === 'workers') {
      assert.equal(new Set(ids).size, N, `contexts share a worker thread: ${ids}`);
      assert.ok(ids.every((id) => id > 0), `a context ran on the main thread: ${ids}`);
    } else {
      assert.deepEqual(ids, [0, 0, 0, 0], `the shared build ran a context off the main thread: ${ids}`);
    }
    console.log(`${variant}: isolates of the ${N} contexts: worker thread ids ${ids}`);
  }
  // state per context
  {
    const { r } = await run({ entry: 'fixtures.js#call_counter', check: CHECK.COUNTER, rows: 100, batches: 5, warmupMin: 1, warmupCap: 1 });
    assert.equal(r.run[R.STATUS], 0, r.message);
    for (const [i, t] of r.threads.entries()) {
      assert.equal(t[T.FIRST_VALUE], 1, `thread ${i}: its module-level counter did not start at 1: state is shared across contexts`);
      assert.equal(t[T.INCREASING], 1);
      assert.equal(t[T.LAST_VALUE], t[T.ROWS], `thread ${i}: the counter ran past the rows this context processed`);
    }
  }
  // memory_report: the model each context holds
  {
    const { r } = await run({ entry: 'model.js#score', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g', threads: 2, batches: 2, warmupMin: 1, warmupCap: 1 });
    assert.equal(r.run[R.STATUS], 0, r.message);
    for (const [i, t] of r.threads.entries()) {
      assert.ok(t[T.MEMORY_REPORT] >= 16 * 1024 * 1024, `thread ${i}: memory_report ${t[T.MEMORY_REPORT]} is under the 16 MiB model`);
    }
    console.log(`${variant}: memory_report per context ${r.threads.map((t) => (t[T.MEMORY_REPORT] / 1048576).toFixed(1)).join(', ')} MiB`);
  }
  // parallelism (a shared farm worker can deschedule a spinning thread, so the
  // workers build gets three tries: a lock across engine threads fails all three)
  {
    let ratio = 0;
    let cpus = 0;
    let line = '';
    for (let attempt = 0; attempt < (variant === 'workers' ? 3 : 1); attempt++) {
      const { r } = await run({ entry: 'fixtures.js#spin', argFmt: 'g', resultFmt: 'g', rows: 1, base: 200, step: 0, batches: 2, warmupMin: 1, warmupCap: 1 });
      assert.equal(r.run[R.STATUS], 0, r.message);
      cpus = r.run[R.CPUS];
      const wall = r.run[R.WALL_NS];
      const cpu = r.run[R.CPU_USER_NS] + r.run[R.CPU_SYS_NS];
      ratio = cpu / wall;
      line = `CPU ${(cpu / 1e6).toFixed(0)} ms in wall ${(wall / 1e6).toFixed(0)} ms: CPU/wall ${ratio.toFixed(2)} on ${cpus} CPUs`;
      console.log(`${variant}: spin x${N} (try ${attempt + 1}): ${line}`);
      if (variant !== 'workers' || ratio >= 0.6 * Math.min(N, cpus)) break;
    }
    const cores = Math.min(N, cpus);
    if (variant === 'workers') {
      if (cores >= 2) assert.ok(ratio >= 0.6 * cores, `CPU/wall ${ratio.toFixed(2)} is under ${(0.6 * cores).toFixed(1)}: a lock across engine threads`);
    } else {
      assert.ok(ratio <= 1.3, `CPU/wall ${ratio.toFixed(2)} is over 1.3: the baseline must stay behind its one isolate`);
    }
  }
  // a call on the JavaScript thread of the environment that runs it
  {
    const t = engine.openContextHere(handle);
    assert.equal(t.status, STATUS.INTERNAL, `open_context on the JavaScript thread: ${t.status} ${t.message}`);
    assert.ok(t.message.includes('JavaScript thread'), t.message);
  }
  engine.engineClose(handle);
  console.log(`threads ${variant}: ok`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
