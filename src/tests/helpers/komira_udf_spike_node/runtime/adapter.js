// The JavaScript half of the Node runtime (rt_js.c calls these methods; the
// design is docs/design/udf_runtime_interface.md section 5.3). Test-only
// spike code.
//
// One adapter per environment (the main thread or one worker_threads
// thread). It loads the user's bundle, binds a user function to a shape,
// loops over the rows or batches, and answers the C side with plain arrays:
//
//   [0, ...payload]                              success
//   [status, message, trace|null, row, group]    failure (never an exception)
//
// A column that crosses from C is [length, offset, nullCount, validity|null,
// values], the two buffers ArrayBuffers over the engine's memory (zero copy,
// detached when the request ends: a view the user's code kept is empty
// afterwards). A column that goes back is [length, typedArray, validity|null];
// the C side copies it out.
//
// User code is exactly what a user writes: a TypeScript per-row function, a
// batch function over Arrow vectors (apache-arrow's Vector, from the base
// image's node_modules, never bundled), a row function over a record of the
// declared fields, an aggregate object, or a generator over batches. The
// result type is not read from the function (TypeScript's types are erased):
// it is the plan's declared type, which arrives in the spec.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const v8 = require('node:v8');
const { createRequire } = require('node:module');

const ERR = {
  DESCRIPTOR: 2, UNSUPPORTED: 3, LOAD: 5, RAISED: 6, RETURN_TYPE: 7, CANCELLED: 11, DEADLINE: 12,
  INTERNAL: 15, FIELD_NOT_DECLARED: 16,
};
const SHAPE = { SCALAR: 1, ROW: 2, COLUMN: 4, FRAME: 8, AGG_PLAIN: 32, AGG_MERGEABLE: 64, STEP: 128 };
const NULL_PROPAGATE = 2;
const TA = { i: Int32Array, l: BigInt64Array, g: Float64Array };
const TYPE_NAME = { i: 'int32', l: 'int64', g: 'float64' };
const INT64_MIN = -(2n ** 63n);
const INT64_MAX = 2n ** 63n - 1n;
// The cancel flag and deadline are polled at every row of the first rows of a
// call, then every POLL_EVERY rows: a slow row is seen at once, a fast loop
// pays one native call per POLL_EVERY rows.
const POLL_FIRST = 64;
const POLL_EVERY = 64;

// An error with the status it must end the call with.
class KErr extends Error {
  constructor(status, message, row = -1) {
    super(message);
    this.status = status;
    this.row = row;
  }
}

// Raised by the row view for a field outside the read set.
class FieldNotDeclared extends KErr {
  constructor(message, row) {
    super(ERR.FIELD_NOT_DECLARED, message, row);
  }
}

const fail = (status, message, trace = null, row = -1, group = -1) => [status, message, trace, row, group];

// An exception from user code (or a KErr) as the answer for `row`.
function failure(e, row) {
  if (e instanceof KErr) return fail(e.status, e.message, e.status === ERR.RAISED ? e.stack : null, e.row >= 0 ? e.row : row);
  const message = e && e.message !== undefined ? String(e.message) : String(e);
  return fail(ERR.RAISED, message || 'the function threw an empty error', e && e.stack ? String(e.stack) : null, row);
}

// ---- reading a column ------------------------------------------------------

// A column descriptor from C as typed views: values are indexed by
// offset + row, validity bits likewise.
function view(c, fmt) {
  const [length, off, nullCount, valid, vals] = c;
  return {
    length, off, nullCount, fmt,
    vals: new TA[fmt](vals),
    valid: valid === null ? null : new Uint8Array(valid),
  };
}

// The value of row i: null where the validity bit is clear.
function getter(v) {
  const { vals, valid, off } = v;
  if (valid === null || v.nullCount === 0) return (i) => vals[off + i];
  return (i) => {
    const k = off + i;
    return (valid[k >> 3] >> (k & 7)) & 1 ? vals[k] : null;
  };
}

// ---- writing a result ------------------------------------------------------

function storeFor(fmt) {
  if (fmt === 'g') {
    return (out, row, v) => {
      if (typeof v !== 'number') throw new KErr(ERR.RETURN_TYPE, `a ${typeof v} was returned for a float64 result`, row);
      out[row] = v;
    };
  }
  if (fmt === 'l') {
    return (out, row, v) => {
      if (typeof v === 'bigint') {
        if (v < INT64_MIN || v > INT64_MAX) throw new KErr(ERR.RETURN_TYPE, `${v} does not fit an int64 result`, row);
        out[row] = v;
      } else if (typeof v === 'number' && Number.isSafeInteger(v)) {
        out[row] = BigInt(v);
      } else {
        throw new KErr(ERR.RETURN_TYPE, `${typeof v === 'number' ? v : typeof v} is not an integer for an int64 result`, row);
      }
    };
  }
  return (out, row, v) => {
    if (typeof v !== 'number' || !Number.isInteger(v) || v < -2147483648 || v > 2147483647)
      throw new KErr(ERR.RETURN_TYPE, `${typeof v === 'number' ? v : typeof v} is not an int32 result`, row);
    out[row] = v;
  };
}

function setNull(valid, row) {
  valid[row >> 3] &= ~(1 << (row & 7));
}

// Anything a user function may return for a column, as [length, values, validity|null].
function normColumn(c, fmt) {
  const T = TA[fmt];
  if (c instanceof T) return [c.length, c, null];
  if (ArrayBuffer.isView(c)) throw new KErr(ERR.RETURN_TYPE, `a ${c.constructor.name} was returned for a ${TYPE_NAME[fmt]} result`);
  if (c !== null && typeof c === 'object' && typeof c.isValid === 'function' && c.data !== undefined) {
    // An Arrow vector. A sliced Data keeps its values already offset.
    const n = c.length;
    const vals = c.data.length === 1 ? c.data[0].values.subarray(0, n) : c.toArray();
    if (!(vals instanceof T)) throw new KErr(ERR.RETURN_TYPE, `a vector of ${c.type} was returned for a ${TYPE_NAME[fmt]} result`);
    let valid = null;
    if (c.nullCount > 0) {
      valid = new Uint8Array((n + 7) >> 3).fill(255);
      for (let i = 0; i < n; i++) if (!c.isValid(i)) setNull(valid, i);
    }
    return [n, vals, valid];
  }
  if (Array.isArray(c)) {
    const n = c.length;
    const out = new T(n);
    const store = storeFor(fmt);
    let valid = null;
    for (let i = 0; i < n; i++) {
      const v = c[i];
      if (v === null || v === undefined) {
        if (valid === null) valid = new Uint8Array((n + 7) >> 3).fill(255);
        setNull(valid, i);
      } else {
        store(out, i, v);
      }
    }
    return [n, out, valid];
  }
  throw new KErr(ERR.RETURN_TYPE, `${c === null ? 'null' : typeof c} was returned for a ${TYPE_NAME[fmt]} column`);
}

// A table a generator yields: an array of columns, or { length, columns }.
function normTable(spec, t) {
  const cols = Array.isArray(t) ? t : t && Array.isArray(t.columns) ? t.columns : null;
  if (cols === null) throw new KErr(ERR.RETURN_TYPE, 'a frame function must yield an array of columns or { length, columns }');
  if (cols.length !== spec.result.length)
    throw new KErr(ERR.RETURN_TYPE, `a table of ${cols.length} columns was yielded for a result of ${spec.result.length}`);
  const out = cols.map((c, i) => normColumn(c, spec.result[i][0]));
  const length = !Array.isArray(t) && typeof t.length === 'number' ? t.length : out.length > 0 ? out[0][0] : 0;
  return [length, out];
}

// ---- Arrow vectors for the user's batch functions --------------------------

let arrowModule = null;
function arrow() {
  if (arrowModule === null) arrowModule = require('apache-arrow');
  return arrowModule;
}

function vector(c, fmt) {
  const A = arrow();
  const [length, off, nullCount, valid, vals] = c;
  const type = fmt === 'g' ? new A.Float64() : fmt === 'l' ? new A.Int64() : new A.Int32();
  // Arrow JS keeps a sliced Data's values already offset and its validity
  // bitmap whole, indexed by offset + row.
  const values = new TA[fmt](vals).subarray(off, off + length);
  const data = A.makeData({
    type, offset: off, length, nullCount,
    nullBitmap: valid === null ? undefined : new Uint8Array(valid),
    data: values,
  });
  return new A.Vector([data]);
}

// ---- the user's module -----------------------------------------------------

// A fresh evaluation of the bundle per context: module-level state of two
// contexts is never shared, in either build.
function loadModule(opts, ctx, file) {
  const cached = ctx.modules.get(file);
  if (cached !== undefined) return cached;
  const full = path.join(opts.codeDir, file);
  const src = fs.readFileSync(full, 'utf8');
  const mod = { exports: {} };
  const wrapper = vm.runInThisContext(
    `(function (exports, require, module, __filename, __dirname) {${src}\n})`, { filename: full });
  wrapper.call(mod.exports, mod.exports, createRequire(full), mod, full, path.dirname(full));
  // A bundle may replace module.exports (esbuild's CJS output does).
  ctx.modules.set(file, mod.exports);
  return mod.exports;
}

// ---- rows of a ROW function ------------------------------------------------

// One reused record per batch. Its getters read the declared fields of the
// current row; any other name records the violation and throws, so that a
// function that catches the throw still fails the batch.
function rowRecord(spec, views, state) {
  const getters = new Map();
  spec.args.forEach((a, i) => getters.set(a[1], getter(views[i])));
  const declared = spec.args.map((a) => a[1]);
  return new Proxy(Object.create(null), {
    get(_t, p) {
      if (typeof p === 'symbol') return undefined;
      const g = getters.get(p);
      if (g !== undefined) return g(state.row);
      if (state.violation === null) state.violation = { name: p, row: state.row };
      throw new FieldNotDeclared(
        `field '${p}' is not in the read set {${declared.join(', ')}}; add it to columns=[...]`, state.row);
    },
    has: (_t, p) => getters.has(p),
    ownKeys: () => declared,
    getOwnPropertyDescriptor: (_t, p) => (getters.has(p) ? { enumerable: true, configurable: true, value: getters.get(p)(state.row) } : undefined),
  });
}

// ---- the adapter -----------------------------------------------------------

function create(native, opts) {
  const workers = new Map();

  const poll = (row) => {
    if (row >= POLL_FIRST && (row % POLL_EVERY) !== 0) return null;
    const st = native.interrupted();
    if (st === 0) return null;
    return fail(st, st === ERR.CANCELLED ? `cancelled before row ${row}` : `the deadline passed before row ${row}`, null, row);
  };

  // SCALAR: the function once per row, in a loop here.
  function callScalar(inst, len, cols) {
    const { spec, fn } = inst;
    const ofmt = spec.result[0][0];
    const views = cols.map((c, i) => view(c, spec.args[i][0]));
    const gets = views.map(getter);
    const out = new TA[ofmt](len);
    const store = storeFor(ofmt);
    let valid = null;
    const n = gets.length;
    let row = 0;
    try {
      for (; row < len; row++) {
        const stop = poll(row);
        if (stop !== null) return stop;
        const v = n === 0 ? fn() : n === 1 ? fn(gets[0](row)) : n === 2 ? fn(gets[0](row), gets[1](row)) : fn(...gets.map((g) => g(row)));
        if (v === null || v === undefined) {
          if (valid === null) valid = new Uint8Array((len + 7) >> 3).fill(255);
          setNull(valid, row);
        } else {
          store(out, row, v);
        }
      }
    } catch (e) {
      return failure(e, row);
    }
    return [0, [len, out, valid]];
  }

  // ROW: the function over a record of the declared fields.
  function callRow(inst, len, cols) {
    const { spec, fn } = inst;
    const ofmt = spec.result[0][0];
    const views = cols.map((c, i) => view(c, spec.args[i][0]));
    const state = { row: 0, violation: null };
    const record = rowRecord(spec, views, state);
    const out = new TA[ofmt](len);
    const store = storeFor(ofmt);
    let valid = null;
    try {
      for (; state.row < len; state.row++) {
        const stop = poll(state.row);
        if (stop !== null) return stop;
        const v = fn(record);
        if (v === null || v === undefined) {
          if (valid === null) valid = new Uint8Array((len + 7) >> 3).fill(255);
          setNull(valid, state.row);
        } else {
          store(out, state.row, v);
        }
      }
    } catch (e) {
      return failure(e, state.row);
    }
    // A read outside the read set that the function caught still fails the batch.
    if (state.violation !== null) {
      const { name, row } = state.violation;
      return fail(ERR.FIELD_NOT_DECLARED,
        `field '${name}' is not in the read set {${inst.spec.args.map((a) => a[1]).join(', ')}}; add it to columns=[...]`, null, row);
    }
    return [0, [len, out, valid]];
  }

  // MAP_BATCHES_COLUMN: the function once, over Arrow vectors (or, for a
  // function marked raw, over the typed arrays: the boundary without Arrow JS).
  function callColumn(inst, len, cols) {
    const { spec, fn } = inst;
    const ofmt = spec.result[0][0];
    const stop = poll(0);
    if (stop !== null) return stop;
    try {
      const args = fn.raw === true
        ? cols.map((c, i) => view(c, spec.args[i][0]).vals.subarray(c[1], c[1] + c[0]))
        : cols.map((c, i) => vector(c, spec.args[i][0]));
      return [0, normColumn(fn(...args), ofmt)];
    } catch (e) {
      return failure(e, -1);
    }
  }

  function callBatch(inst, len, cols) {
    switch (inst.shape) {
      case SHAPE.SCALAR: return callScalar(inst, len, cols);
      case SHAPE.ROW: return callRow(inst, len, cols);
      default: return callColumn(inst, len, cols);
    }
  }

  // ---- frames: generators over batches, steps, plain aggregates -------------

  function iterOf(x) {
    if (x !== null && typeof x === 'object' && typeof x.next === 'function') return x;
    if (x !== null && typeof x === 'object' && typeof x[Symbol.iterator] === 'function') return x[Symbol.iterator]();
    throw new KErr(ERR.RETURN_TYPE, 'a frame function must return an iterator or an iterable of tables');
  }

  function batchVectors(inst, b) {
    const [, cols] = b;
    return cols.map((c, i) => vector(c, inst.spec.args[i][0]));
  }

  function frameOpen(inst, pull) {
    const f = { inst, pull, it: null, ended: false, cur: null, curArgs: null, count: 0 };
    try {
      if (inst.shape === SHAPE.FRAME) {
        const input = {
          [Symbol.iterator]() { return this; },
          next() {
            const b = pull();
            return b === null ? { done: true, value: undefined } : { done: false, value: batchVectors(inst, b) };
          },
        };
        f.it = iterOf(inst.fn(input));
      } else if (inst.shape === SHAPE.STEP) {
        const b = pull();
        if (b === null) return fail(ERR.INTERNAL, 'a step got no literal batch');
        const lits = b[1].map((c, i) => getter(view(c, inst.spec.args[i][0]))(0));
        f.it = iterOf(inst.fn(...lits));
      }
    } catch (e) {
      return failure(e, -1);
    }
    return [0, f];
  }

  // The user's function over one group's values; the groups completed so far.
  function endGroup(f, results) {
    results.push(f.inst.fn(...f.curArgs));
    f.cur = null;
  }

  function nextPlain(f) {
    const { inst } = f;
    const spec = inst.spec;
    const results = [];
    while (results.length === 0 && !f.ended) {
      const b = f.pull();
      if (b === null) {
        f.ended = true;
        if (f.cur !== null) endGroup(f, results);
        break;
      }
      const [len, cols] = b;
      const group = view(cols[0], 'l');
      const gets = cols.slice(1).map((c, i) => getter(view(c, spec.args[i][0])));
      for (let r = 0; r < len; r++) {
        const g = group.vals[group.off + r];
        if (f.cur === null || f.cur !== g) {
          if (f.cur !== null) endGroup(f, results);
          f.cur = g;
          f.curArgs = gets.map(() => []);
        }
        for (let k = 0; k < gets.length; k++) f.curArgs[k].push(gets[k](r));
      }
    }
    return results;
  }

  function frameNext(f) {
    const stop = poll(0);
    if (stop !== null) return stop;
    const { inst } = f;
    try {
      if (inst.shape === SHAPE.AGG_PLAIN) {
        const results = nextPlain(f);
        if (results.length === 0) return [0, 0];
        return [0, 1, [results.length, [normColumn(results, inst.spec.result[0][0])]]];
      }
      const r = f.it.next();
      if (r.done) return [0, 0];
      return [0, 1, normTable(inst.spec, r.value)];
    } catch (e) {
      return failure(e, -1);
    }
  }

  // ---- mergeable aggregates, vectorized over groups -------------------------

  function aggUpdate(g, len, cols, ids, nGroups) {
    const { inst } = g;
    const { agg, spec } = inst;
    const gets = cols.map((c, i) => getter(view(c, spec.args[i][0])));
    const idv = view(ids, 'i');
    let row = 0;
    try {
      while (g.states.length < nGroups) g.states.push(agg.init());
      for (; row < len; row++) {
        const stop = poll(row);
        if (stop !== null) return stop;
        const gid = idv.vals[idv.off + row];
        if (gid < 0 || gid >= nGroups) return fail(ERR.INTERNAL, 'a group id is not below n_groups', null, row);
        g.states[gid] = agg.update(g.states[gid], ...gets.map((get) => get(row)));
      }
    } catch (e) {
      return failure(e, row);
    }
    return [0];
  }

  function aggMerge(g, len, col, ids, nGroups) {
    const { agg, spec } = g.inst;
    const get = getter(view(col, spec.state[0][0]));
    const idv = view(ids, 'i');
    let row = 0;
    try {
      while (g.states.length < nGroups) g.states.push(agg.init());
      for (; row < len; row++) {
        const stop = poll(row);
        if (stop !== null) return stop;
        const gid = idv.vals[idv.off + row];
        if (gid < 0 || gid >= nGroups) return fail(ERR.INTERNAL, 'a group id is not below n_groups', null, row);
        g.states[gid] = agg.merge(g.states[gid], get(row));
      }
    } catch (e) {
      return failure(e, row);
    }
    return [0];
  }

  // Emit the first n groups' states or results and forget them.
  function aggEmit(g, n, finish) {
    if (n > g.states.length) return fail(ERR.INTERNAL, 'emit_first_n is above the group count');
    const { agg, spec } = g.inst;
    try {
      const taken = g.states.splice(0, n);
      const values = finish ? taken.map((s) => agg.finish(s)) : taken;
      return [0, normColumn(values, finish ? spec.result[0][0] : spec.state[0][0])];
    } catch (e) {
      return failure(e, -1);
    }
  }

  // ---- the table of methods rt_js.c calls -----------------------------------

  return {
    openContext(slot) {
      return [0, { slot, modules: new Map() }];
    },
    closeContext(ctx) {
      ctx.modules.clear();
      return [0];
    },
    openInstance(ctx, spec) {
      const hash = spec.entry.indexOf('#');
      const file = spec.entry.slice(0, hash);
      const name = spec.entry.slice(hash + 1);
      let target;
      try {
        target = loadModule(opts, ctx, file)[name];
      } catch (e) {
        return fail(ERR.LOAD, `loading ${file} failed: ${e && e.message}`, e && e.stack ? String(e.stack) : null);
      }
      const inst = { ctx, spec, shape: spec.shape, fn: null, agg: null };
      if (spec.shape === SHAPE.AGG_MERGEABLE) {
        const ok = target !== null && typeof target === 'object' &&
          ['init', 'update', 'merge', 'finish'].every((m) => typeof target[m] === 'function');
        if (!ok) return fail(ERR.LOAD, `${spec.entry} is not an aggregate { init, update, merge, finish }`);
        inst.agg = target;
      } else {
        if (typeof target !== 'function') return fail(ERR.LOAD, `${spec.entry} is not a function`);
        inst.fn = target;
      }
      return [0, inst];
    },
    closeInstance() {
      return [0];
    },
    callBatch,
    frameOpen,
    frameNext,
    frameClose() {
      return [0];
    },
    aggOpen(inst) {
      return [0, { inst, states: [] }];
    },
    aggUpdate,
    aggMerge,
    aggState: (g, n) => aggEmit(g, n, false),
    aggFinish: (g, n) => aggEmit(g, n, true),
    aggClose() {
      return [0];
    },
    memory() {
      const h = v8.getHeapStatistics();
      return [0, h.used_heap_size + h.external_memory];
    },
    // The main environment starts the worker of a slot (the workers build).
    spawnWorker(slot, addonPath, codeDir) {
      const { Worker } = require('node:worker_threads');
      const w = new Worker(path.join(codeDir, 'worker.js'), { workerData: { slot, addonPath, codeDir } });
      w.on('error', (e) => native.workerFailed(slot, `the worker of slot ${slot} failed: ${e && e.message}`));
      // An earlier worker of this slot may exit after this one started.
      w.on('exit', () => { if (workers.get(slot) === w) workers.delete(slot); });
      workers.set(slot, w);
      return [0];
    },
    stopWorker(slot) {
      const w = workers.get(slot);
      if (w !== undefined) w.terminate();
      return [0];
    },
  };
}

module.exports = { create, ERR, NULL_PROPAGATE };
