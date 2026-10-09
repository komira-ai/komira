// Frames (MAP_BATCHES_FRAME, AGG_PLAIN, STEP) and mergeable aggregates
// (AGG_MERGEABLE), worker side (design section 4.3, step 7).
//
// A frame pulls its input when user code asks for it. The engine drives a
// frame with FRAME_OUT; when the frame needs an input batch before it can
// yield, the worker answers OK with no batch and no END, and blocks for the
// FRAME_IN the engine then sends, whose reply is the frame's next answer.
// User code iterates its input as an ordinary iterator: the exchange happens
// inside that iterator's next(), so a generator yields as it goes, before it
// has read all its input.

import { RecordBatch, Schema, Struct, makeData } from 'apache-arrow';
import { batchParts, fieldOf, readBatch, readMessages, toVector } from './arrow_io.mjs';
import { Out, ST, UdfError, raised, reader, toColumn } from './calls.mjs';
import { FLAG_END, OP, nextRequest, pushBack, reply, replyError } from './wire.mjs';

class Aborted extends Error {}

// An output (a table or a column) as {length, cols} for `result`.
export function outputOf(x, result) {
  if (!result.isTable) {
    const c = toColumn(x, result.fields[0].fmt);
    return { length: c.values.length, cols: [c] };
  }
  const fields = result.fields;
  let length;
  let parts;
  if (x !== null && typeof x === 'object' && typeof x.getChildAt === 'function' && 'numRows' in x) {
    if (x.numCols !== undefined && x.numCols !== fields.length)
      throw new UdfError(ST.RETURN_TYPE, `a table of ${x.numCols} columns for ${fields.length} declared`);
    length = x.numRows;
    parts = fields.map((_, i) => x.getChildAt(i));
  } else if (x !== null && typeof x === 'object' && Array.isArray(x.columns)) {
    if (x.columns.length !== fields.length)
      throw new UdfError(ST.RETURN_TYPE, `a table of ${x.columns.length} columns for ${fields.length} declared`);
    length = x.numRows ?? (x.columns.length > 0 ? x.columns[0].length : 0);
    parts = x.columns;
  } else {
    throw new UdfError(ST.RETURN_TYPE, 'a frame yielded something that is not a table ({numRows, columns} or an apache-arrow RecordBatch or Table)');
  }
  const cols = fields.map((f, i) => toColumn(parts[i], f.fmt));
  for (const c of cols)
    if (c.values.length !== length) throw new UdfError(ST.RETURN_TYPE, `a table column of ${c.values.length} rows in a table of ${length}`);
  return { length, cols };
}

function recordBatchOf(b, fields) {
  const schema = new Schema(fields.map((f) => fieldOf(f.name, f.fmt, f.nullable)));
  const children = b.cols.map((c) => toVector(c).data[0]);
  return new RecordBatch(schema, makeData({ type: new Struct(schema.fields), length: b.length, nullCount: 0, children }));
}

// Plain aggregate: rows of one group are contiguous, the group ordinal is
// the first column; the user's function runs once per group over arrays of
// that group's values; each output is the groups completed by one input.
function* aggPlain(fn, inputs) {
  let cur = null;
  let acc = null;
  let done = [];
  const finish = () => {
    try {
      done.push(fn(...acc));
    } catch (e) {
      throw raised(e, -1, Number(cur));
    }
  };
  for (const b of inputs) {
    const g = b.cols[0].values;
    const rd = b.cols.slice(1).map(reader);
    for (let r = 0; r < b.length; r++) {
      if (cur !== null && g[r] !== cur) {
        finish();
        acc = null;
      }
      cur = g[r];
      if (acc === null) acc = rd.map(() => []);
      for (let j = 0; j < rd.length; j++) acc[j].push(rd[j](r));
    }
    if (done.length > 0) {
      yield done;
      done = [];
    }
  }
  if (cur !== null) finish();
  if (done.length > 0) yield done;
}

// STEP: the one input row's values are the literal arguments; the function
// returns a table, or an iterable of tables.
function* step(fn, inputs) {
  let args = [];
  for (const b of inputs) {
    if (b.length > 0) args = b.cols.map((c) => reader(c)(0));
  }
  let x;
  try {
    x = fn(...args);
  } catch (e) {
    throw raised(e, 0);
  }
  if (x !== null && typeof x === 'object' && typeof x[Symbol.iterator] === 'function' && !('numRows' in x)) yield* x;
  else yield x;
}

export class Frame {
  constructor(id, inst, shape) {
    this.id = id;
    this.inst = inst;
    this.shape = shape;
    this.queue = [];
    this.ended = false;
    this.done = false;
    this.aborted = false;
    this.it = null;
    this.pending = null;
    const u = inst.udf;
    this.inputFields = shape === 'AGG_PLAIN' ? [{ name: 'group', fmt: 'l', nullable: false }, ...u.args] : u.args;
  }

  *inputs() {
    for (;;) {
      if (this.queue.length > 0) {
        yield this.queue.shift();
        continue;
      }
      if (this.ended) return;
      this.needInput();
    }
  }

  needInput() {
    reply(this.pending.id, 0);
    const m = nextRequest();
    if (m.op !== OP.FRAME_IN || m.handle !== this.id) {
      pushBack(m);
      this.aborted = true;
      throw new Aborted('the engine sent another request while the frame waited for input');
    }
    this.pending = m;
    if ((m.flags & FLAG_END) !== 0) this.ended = true;
    else this.queue.push(readBatch(readMessages(m.body)[0], this.inputFields));
  }

  start() {
    const fn = this.inst.fn;
    if (this.shape === 'AGG_PLAIN') return aggPlain(fn, this.inputs());
    if (this.shape === 'STEP') return step(fn, this.inputs());
    const self = this;
    const batches = (function* () {
      for (const b of self.inputs()) yield recordBatchOf(b, self.inputFields);
    })();
    const it = fn(batches);
    if (it === null || typeof it !== 'object' || typeof it.next !== 'function')
      throw new UdfError(ST.RETURN_TYPE, 'a frame function returned no iterator (write it as a generator: function*)');
    return it;
  }

  // FRAME_OUT: the frame's next output, its end, or (inside the input
  // iterator) a request for input.
  out(req) {
    this.pending = req;
    if (this.done) {
      reply(req.id, FLAG_END);
      return;
    }
    let r;
    try {
      if (this.it === null) this.it = this.start();
      r = this.it.next();
      if (this.aborted) return;
      if (r.done) {
        this.done = true;
        reply(this.pending.id, FLAG_END);
        return;
      }
      const o = outputOf(r.value, this.inst.udf.result);
      reply(this.pending.id, 0, batchParts(o.length, o.cols));
    } catch (e) {
      if (e instanceof Aborted || this.aborted) return;
      this.done = true;
      const u = raised(e, -1);
      replyError(this.pending.id, u.code, u.message, u);
    }
  }

  close() {
    if (this.it !== null && !this.aborted) {
      try {
        this.it.return();
      } catch {
        // a generator's finally that throws: nothing left to report to
      }
    }
  }
}

// Mergeable aggregate: one state per group, vectorized over a batch's rows.
export class Groups {
  constructor(inst) {
    this.inst = inst;
    this.agg = inst.fn;
    this.states = [];
  }

  grow(n) {
    while (this.states.length < n) this.states.push(this.agg.init());
  }

  update(req, merge) {
    const u = this.inst.udf;
    const fields = merge ? [u.state.fields[0], { fmt: 'i' }] : [...u.args, { fmt: 'i' }];
    const b = readBatch(readMessages(req.body)[0], fields);
    const ids = b.cols[b.cols.length - 1].values;
    const rd = b.cols.slice(0, -1).map(reader);
    this.grow(req.nGroups);
    let r = 0;
    let g = -1;
    try {
      for (; r < b.length; r++) {
        g = ids[r];
        if (g < 0 || g >= req.nGroups) throw new UdfError(ST.INTERNAL, `group id ${g} at row ${r} is not below n_groups ${req.nGroups}`);
        if (merge) this.states[g] = this.agg.merge(this.states[g], rd[0](r));
        else this.states[g] = this.agg.update(this.states[g], ...rd.map((f) => f(r)));
      }
    } catch (e) {
      throw raised(e, r, g);
    }
  }

  emit(n, finish) {
    const u = this.inst.udf;
    const fmt = finish ? u.result.fields[0].fmt : u.state.fields[0].fmt;
    this.grow(n);
    const o = new Out(fmt, n);
    let g = 0;
    try {
      for (; g < n; g++) o.set(g, finish ? this.agg.finish(this.states[g]) : this.states[g]);
    } catch (e) {
      throw raised(e, -1, g);
    }
    this.states.splice(0, n);
    return o.column();
  }
}
