// The Node runtime's measurements (node_bench in BUCK): one JSON object on
// stdout. Run as `node bench.js <run id>`; each build runs in a child process
// of its own (`node bench.js child <build> <run id>`), so one build's isolates
// never sit in the other's resident memory.
//
// What is measured, inside the engine loop (engine_loop.c, CLOCK_MONOTONIC
// around the table entry alone):
//   - the cost of one crossing: a batch of 0 and of 1 row through the raw path
//     (typed arrays, no Arrow vector built: the boundary alone) and through a
//     function over an Arrow vector (identity): median ns per call;
//   - rows/s for a per-row function (fahrenheit_rows) and a batch function over
//     Arrow vectors (fahrenheit_batch) at 1k, 8k and 64k rows, and at 1, 4 and
//     16 engine threads: rows/s, rows/s per thread, efficiency = rows/s(N) /
//     (N x rows/s(1)) at 8k rows. Each is run three times and the middle run
//     (by rows/s) is reported, the three beside it;
//   - warm-up: calls discarded until three consecutive windows of 8 calls have
//     medians within 2% (V8 tiers a hot function up in steps), capped at 400;
//     the count is reported;
//   - CPU time beside wall time (getrusage), involuntary context switches,
//     cgroup cpu.max and the throttling counters before and after every run,
//     load average, CPUs in the affinity mask; a row is `noisy` when its CPU
//     time is under 0.8 x wall x min(threads, CPUs), and `not_measured` when
//     the threads outnumber the CPUs;
//   - memory per isolate, each N in a fresh process (`node bench.js mem <build> <N> <kind>`,
//     so no earlier run's freed memory sits in the baseline): the RSS and PSS
//     of the process before and with N contexts open, divided by N, for a bare
//     function and for one whose bundle holds a 16 MiB model; the V8 heap and
//     external memory each context reports (memory_report);
//   - cold start: the addon's load, the engine's dlopen + init, and dlopen to
//     the end of the first batch (which includes, for the workers build, the
//     start of a worker_threads isolate and its load of apache-arrow);
//   - the copy path (arguments copied into V8's memory, as a node without
//     external buffers does) against the external path;
//   - the finalizer-to-reclaim gap: what an engine array held until its
//     ArrayBuffer's finalizer would cost (the runtime releases at return
//     instead, and detaches).
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const v8 = require('node:v8');
const { spawnSync } = require('node:child_process');
const h = require('../tests/helpers.js');

const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };

function cgroup() {
  const max = readText('/sys/fs/cgroup/cpu.max');
  const stat = readText('/sys/fs/cgroup/cpu.stat');
  const pick = (k) => { const m = stat && new RegExp(`^${k} (\\d+)`, 'm').exec(stat); return m ? Number(m[1]) : null; };
  return { cpu_max: max ? max.trim() : null, nr_throttled: pick('nr_throttled'), throttled_usec: pick('throttled_usec') };
}

function pssKb() {
  const t = readText('/proc/self/smaps_rollup');
  const m = t && /^Pss:\s+(\d+) kB/m.exec(t);
  return m ? Number(m[1]) : null;
}

function environment() {
  const cpuinfo = readText('/proc/cpuinfo');
  const model = cpuinfo && /^model name\s*:\s*(.+)$/m.exec(cpuinfo);
  return {
    node: process.version, v8: process.versions.v8, arch: process.arch, platform: process.platform,
    cpu_model: model ? model[1] : null, cpus_online: os.cpus().length, loadavg: os.loadavg(),
    build: { runtime_c: '-O2 (c_shared_lib)', engine_loop_c: '-O2 (c_shared_lib)', js: 'V8 default tiering' },
  };
}

function percentile(sorted, p) {
  return sorted.length === 0 ? 0 : sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
}

async function child(variant, runId) {
  const t0 = performance.now();
  const { addon, file } = h.loadRuntime(variant);
  const loadMs = performance.now() - t0;
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  const info = engine.engineInfo(handle);
  if (info.status !== 0) throw new Error(info.message);
  const { SHAPE, R, T } = h;
  const out = { variant, runtime_id: info.runtimeId, global_lock: info.globalLock, addon_load_ms: loadMs, engine_open_ms: info.openNs / 1e6 };

  const measureOnce = async (name, o) => {
    const threads = o.threads || 1;
    const cg0 = cgroup();
    const res = h.summary(await engine.run(handle, {
      nArgs: 1, warmupMin: 16, warmupCap: 400, batches: 40, ...o,
    }));
    const cg1 = cgroup();
    const r = res.run;
    const wall = r[R.WALL_NS];
    const cpu = r[R.CPU_USER_NS] + r[R.CPU_SYS_NS];
    const cpus = r[R.CPUS];
    const all = [];
    for (const s of res.samples) for (const x of s) all.push(x);
    all.sort((a, b) => a - b);
    const calls = threads * (o.batches || 40);
    const rows = o.rows;
    const warm = res.threads.map((t) => t[T.WARMUP_CALLS]).sort((a, b) => a - b);
    const row = {
      name, threads, rows, status: r[R.STATUS], message: res.message,
      rows_per_s: (calls * rows) / (wall / 1e9),
      rows_per_s_per_thread: (calls * rows) / (wall / 1e9) / threads,
      ns_per_call: { min: all[0], median: percentile(all, 0.5), p90: percentile(all, 0.9), max: all[all.length - 1] },
      samples: all.length, warmup_calls_median: warm[warm.length >> 1],
      wall_ms: wall / 1e6, cpu_ms: cpu / 1e6, cpu_over_wall: cpu / wall, involuntary_switches: r[R.INVOLUNTARY],
      cpus, noisy: cpu < 0.8 * wall * Math.min(threads, cpus), not_measured: threads > cpus ? `not measured: ${cpus} cpus` : null,
      cgroup: { cpu_max: cg0.cpu_max, nr_throttled: (cg1.nr_throttled ?? 0) - (cg0.nr_throttled ?? 0), throttled_usec: (cg1.throttled_usec ?? 0) - (cg0.throttled_usec ?? 0) },
    };
    return row;
  };

  // The middle of three runs by rows/s, with the three.
  const measure = async (name, o, repeats = 1) => {
    const runs = [];
    for (let i = 0; i < repeats; i++) runs.push(await measureOnce(name, o));
    const sorted = runs.slice().sort((a, b) => a.rows_per_s - b.rows_per_s);
    const mid = sorted[sorted.length >> 1];
    return repeats === 1 ? mid : { ...mid, repeats_rows_per_s: runs.map((r) => r.rows_per_s) };
  };

  const FN = {
    per_row: { entry: 'fixtures.js#fahrenheit_rows', shape: SHAPE.SCALAR, argFmt: 'g', resultFmt: 'g' },
    batch_vector: { entry: 'fixtures.js#fahrenheit_batch', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g' },
    raw: { entry: 'fixtures.js#identity_raw', shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g' },
  };

  // cold start: the first run of the process (R_COLD_NS: the engine's dlopen to
  // the end of the first batch, which for the workers build includes starting a
  // worker_threads isolate and its load of apache-arrow), then a second one
  {
    const cold = h.summary(await engine.run(handle, { ...FN.per_row, nArgs: 1, rows: 1024, batches: 1, warmupMin: 1, warmupCap: 1, threads: 1 }));
    const again = h.summary(await engine.run(handle, { ...FN.per_row, nArgs: 1, rows: 1024, batches: 1, warmupMin: 1, warmupCap: 1, threads: 1 }));
    const pick = (r) => ({
      status: r.run[R.STATUS], dlopen_to_first_batch_ms: r.run[R.COLD_NS] < 0 ? null : r.run[R.COLD_NS] / 1e6, open_context_ms: r.threads[0][T.OPEN_CONTEXT_NS] / 1e6,
      open_instance_ms: r.threads[0][T.OPEN_INSTANCE_NS] / 1e6, first_call_ms: r.threads[0][T.FIRST_CALL_NS] / 1e6, load_ms: r.run[R.LOAD_NS] / 1e6,
    });
    out.cold_start = { first_run: pick(cold), second_run: pick(again) };
  }

  // one crossing: an empty batch and a one-row batch
  out.crossing = [];
  for (const fn of ['raw', 'batch_vector']) {
    for (const rows of [0, 1]) {
      for (const threads of [1, 4, 16]) {
        out.crossing.push({ fn, ...await measure(`crossing ${fn}`, { ...FN[fn], rows, threads, batches: 200 }, 3) });
      }
    }
  }

  // throughput
  out.throughput = [];
  for (const fn of ['per_row', 'batch_vector', 'raw']) {
    for (const [threads, rows] of [[1, 1024], [1, 8192], [1, 65536], [4, 8192], [16, 8192]]) {
      out.throughput.push({ fn, ...await measure(`throughput ${fn}`, { ...FN[fn], rows, threads }, 3) });
    }
  }
  for (const fn of ['per_row', 'batch_vector', 'raw']) {
    const rate = (n) => out.throughput.find((x) => x.fn === fn && x.threads === n && x.rows === 8192).rows_per_s;
    for (const row of out.throughput) {
      if (row.fn === fn && row.rows === 8192) row.efficiency_vs_1_thread = rate(row.threads) / (row.threads * rate(1));
    }
  }

  // the copy path (a node built without external buffers) against the external
  // path, one engine thread
  out.copy_path = [];
  for (const copy of [false, true]) {
    addon.setCopyMode(copy);
    for (const fn of ['raw', 'batch_vector']) {
      for (const rows of [1024, 8192, 65536]) {
        out.copy_path.push({ copy, fn, ...await measure(`copy_path ${fn}`, { ...FN[fn], rows, threads: 1 }, 3) });
      }
    }
  }
  addon.setCopyMode(false);

  // the finalizer-to-reclaim gap of releasing the engine's array from the
  // ArrayBuffer's finalizer: 2000 blocks of 64 KiB wrapped, never detached
  {
    const base = addon.probeFinalized();
    const made = addon.probeWrapMany(2000, 65536);
    const sample = async (ms) => { await new Promise((r) => setTimeout(r, ms)); return addon.probeFinalized() - base; };
    const afterIdle = await sample(1000);
    v8.setFlagsFromString('--expose-gc');
    const gc = require('node:vm').runInNewContext('gc');
    const tGc = performance.now();
    gc();
    let afterGc = await sample(0);
    let waited = 0;
    while (afterGc < made && waited < 5000) { afterGc = await sample(10); waited += 10; }
    out.finalizer_gap = {
      wrapped: made, bytes_each: 65536, held_bytes: made * 65536,
      finalized_after_1s_idle: afterIdle, finalized_after_forced_gc: afterGc,
      ms_from_forced_gc_to_all_finalized: performance.now() - tGc,
      release_at_return_gap_ms: 0,
    };
  }
  out.stats = addon.stats();
  engine.engineClose(handle);
  console.log(JSON.stringify(out));
}

// Memory with N contexts open, in a process of its own: kind 'bare' loads the
// bundle of plain functions, kind 'model' one that holds a 16 MiB model.
async function memChild(variant, threads, kind) {
  const { addon, file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  const { SHAPE, R, T } = h;
  const one = async (entry) => {
    const res = h.summary(await engine.run(handle, { entry, shape: SHAPE.COLUMN, argFmt: 'g', resultFmt: 'g', nArgs: 1, rows: 1024, threads, batches: 1, warmupMin: 1, warmupCap: 1 }));
    const mu = process.memoryUsage();
    const hs = v8.getHeapStatistics();
    return {
      entry, threads, status: res.run[R.STATUS],
      rss_before_mib: res.run[R.RSS_BEFORE] / 1048576, rss_open_mib: res.run[R.RSS_OPEN] / 1048576,
      rss_delta_per_context_mib: (res.run[R.RSS_OPEN] - res.run[R.RSS_BEFORE]) / threads / 1048576,
      pss_before_mib: res.run[R.PSS_BEFORE] / 1024, pss_open_mib: res.run[R.PSS_OPEN] / 1024,
      pss_delta_per_context_mib: (res.run[R.PSS_OPEN] - res.run[R.PSS_BEFORE]) / threads / 1024,
      memory_report_per_context_mib: res.threads.map((t) => t[T.MEMORY_REPORT] / 1048576),
      open_wall_ms: res.run[R.OPEN_WALL_NS] / 1e6,
      open_context_ms_median: h.median(res.threads.map((t) => t[T.OPEN_CONTEXT_NS])) / 1e6,
      open_instance_ms_median: h.median(res.threads.map((t) => t[T.OPEN_INSTANCE_NS])) / 1e6,
      main_isolate: { rss_mib: mu.rss / 1048576, heap_used_mib: mu.heapUsed / 1048576, external_mib: mu.external / 1048576, v8_malloced_mib: hs.malloced_memory / 1048576 },
    };
  };
  const out = { variant, kind, ...await one(kind === 'model' ? 'model.js#score' : 'fixtures.js#fahrenheit_batch') };
  void addon;
  engine.engineClose(handle);
  console.log(JSON.stringify(out));
}

function parent(runId) {
  const out = { run_id: runId, environment: environment(), cgroup_at_start: cgroup(), builds: {} };
  for (const variant of ['shared', 'workers']) {
    const r = spawnSync(process.execPath, [__filename, 'child', variant, runId], { env: process.env, encoding: 'utf8', timeout: 900000, maxBuffer: 64 << 20 });
    if (r.status !== 0) {
      out.builds[variant] = { error: `exit ${r.status === null ? r.signal : r.status}`, stderr: (r.stderr || '').slice(-2000), stdout: (r.stdout || '').slice(-2000) };
      continue;
    }
    out.builds[variant] = JSON.parse(r.stdout.trim().split('\n').pop());
    out.builds[variant].memory = [];
    for (const kind of ['bare', 'model']) {
      for (const n of [1, 4, 16]) {
        const m = spawnSync(process.execPath, [__filename, 'mem', variant, String(n), kind], { env: process.env, encoding: 'utf8', timeout: 300000, maxBuffer: 16 << 20 });
        out.builds[variant].memory.push(m.status === 0 ? JSON.parse(m.stdout.trim().split('\n').pop()) : { error: `exit ${m.status === null ? m.signal : m.status}`, stderr: (m.stderr || '').slice(-1000) });
      }
    }
  }
  console.log(JSON.stringify(out, null, 1));
}

const args = process.argv.slice(2);
if (args[0] === 'child') {
  child(args[1], args[2]).catch((e) => { console.error(e); process.exit(1); });
} else if (args[0] === 'mem') {
  memChild(args[1], Number(args[2]), args[3]).catch((e) => { console.error(e); process.exit(1); });
} else {
  parent(args[args.length - 1] || 'unlabelled');
}
