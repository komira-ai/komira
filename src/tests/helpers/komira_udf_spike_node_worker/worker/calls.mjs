// The call shapes of the runtime, worker side: per-row (SCALAR, ROW), per
// batch over Arrow vectors (MAP_BATCHES_COLUMN), and the conversions between
// Arrow columns and JavaScript values (design section 6.2: int64 is a
// bigint, and a returned number is accepted while it is a safe integer;
// float64 and int32 are numbers; null is null).
//
// A failure is thrown as a UdfError carrying a komira_udf_status.

import { Vector } from 'apache-arrow';
import { toVector, widthOf } from './arrow_io.mjs';
import { cancelRequested } from './wire.mjs';

export const ST = Object.freeze({
  ABI: 1, DESCRIPTOR: 2, UNSUPPORTED: 3, CODE_DIGEST: 4, LOAD: 5, RAISED: 6, RETURN_TYPE: 7, LENGTH: 8,
  CANCELLED: 11, DEADLINE: 12, INTERNAL: 15, FIELD_NOT_DECLARED: 16,
});

export class UdfError extends Error {
  constructor(code, message, { row = -1, group = -1, trace = '' } = {}) {
    super(message);
    this.code = code;
    this.row = row;
    this.group = group;
    this.trace = trace;
  }
}

export function raised(e, row, group = -1) {
  if (e instanceof UdfError) {
    if (e.row < 0) e.row = row;
    return e;
  }
  const msg = e instanceof Error ? `${e.name}: ${e.message}` : `a thrown value: ${String(e)}`;
  return new UdfError(ST.RAISED, msg, { row, group, trace: e instanceof Error ? e.stack : '' });
}

// The cancel word and the deadline, read between rows: never before row 0
// (the proxy checked both before it sent the call), then about once per
// millisecond of work, so a fast loop pays one read per thousands of rows.
export class Watch {
  constructor(req) {
    this.id = req.id;
    this.deadline = req.deadlineNs > 0n ? process.hrtime.bigint() + req.deadlineNs : 0n;
    this.next = 1;
    this.lastRow = 0;
    this.lastT = process.hrtime.bigint();
  }

  check(row) {
    const now = process.hrtime.bigint();
    if (cancelRequested(this.id)) throw new UdfError(ST.CANCELLED, `cancelled at row ${row}`, { row });
    if (this.deadline !== 0n && now > this.deadline) throw new UdfError(ST.DEADLINE, `deadline passed at row ${row}`, { row });
    const perRow = Number(now - this.lastT) / Math.max(1, row - this.lastRow);
    const every = Math.max(1, Math.min(4096, Math.floor(1e6 / Math.max(perRow, 1))));
    this.lastRow = row;
    this.lastT = now;
    this.next = row + every;
  }
}

// Reading a column's row r as a JavaScript value.
export function reader(col) {
  const v = col.values;
  if (col.nullCount === 0) return (r) => v[r];
  const bits = col.validity;
  return (r) => (((bits[r >> 3] >> (r & 7)) & 1) === 1 ? v[r] : null);
}

// An output column of `n` rows of `fmt`, filled one value at a time.
export class Out {
  constructor(fmt, n) {
    this.fmt = fmt;
    const Ctor = fmt === 'l' ? BigInt64Array : fmt === 'i' ? Int32Array : Float64Array;
    this.values = new Ctor(n);
    this.validity = new Uint8Array(Math.ceil(n / 8) || 1);
    this.nullCount = 0;
    this.length = n;
  }

  set(r, x) {
    if (x === null) {
      this.nullCount++;
      return;
    }
    const f = this.fmt;
    if (f === 'g') {
      if (typeof x !== 'number') throw this.bad(r, x);
      this.values[r] = x;
    } else if (f === 'l') {
      if (typeof x === 'bigint') {
        if (BigInt.asIntN(64, x) !== x) throw this.bad(r, x);
        this.values[r] = x;
      } else if (typeof x === 'number' && Number.isSafeInteger(x)) {
        this.values[r] = BigInt(x);
      } else {
        throw this.bad(r, x);
      }
    } else {
      if (typeof x !== 'number' || !Number.isInteger(x) || x < -2147483648 || x > 2147483647) throw this.bad(r, x);
      this.values[r] = x;
    }
    this.validity[r >> 3] |= 1 << (r & 7);
  }

  bad(r, x) {
    const what = x === undefined ? 'undefined' : typeof x === 'bigint' ? `${x}n` : `${typeof x} ${String(x)}`;
    const want = { l: 'int64 (a bigint or a safe integer)', g: 'float64 (a number)', i: 'int32 (an integer number)' }[this.fmt];
    return new UdfError(ST.RETURN_TYPE, `row ${r}: returned ${what}, not ${want}`, { row: r });
  }

  column() {
    return { fmt: this.fmt, values: this.values, validity: this.nullCount > 0 ? this.validity : null, nullCount: this.nullCount };
  }
}

// SCALAR: the user's function once per row, inside this loop.
export function scalar(fn, req, batch, fmt) {
  const n = batch.length;
  const out = new Out(fmt, n);
  const w = new Watch(req);
  const rd = batch.cols.map(reader);
  const k = rd.length;
  let r = 0;
  try {
    if (k === 1) {
      const a = rd[0];
      for (; r < n; r++) {
        if (r === w.next) w.check(r);
        out.set(r, fn(a(r)));
      }
    } else if (k === 0) {
      for (; r < n; r++) {
        if (r === w.next) w.check(r);
        out.set(r, fn());
      }
    } else {
      const xs = new Array(k);
      for (; r < n; r++) {
        if (r === w.next) w.check(r);
        for (let j = 0; j < k; j++) xs[j] = rd[j](r);
        out.set(r, fn(...xs));
      }
    }
  } catch (e) {
    throw raised(e, r);
  }
  return out.column();
}

const ROW = Symbol('row');

class FieldNotDeclared extends Error {}

// ROW: one row object per row, whose getters read only the read set (the
// argument fields, by name); any other name throws, and is recorded so a
// caught read still fails the batch (design section 4.3, ROW).
export function rowShape(names) {
  const cur = { rd: [], violation: null, readSet: names.join(', ') };
  const guard = new Proxy(Object.create(null), {
    get(_t, key, recv) {
      if (typeof key === 'symbol') return undefined;
      const row = recv[ROW];
      if (cur.violation === null) cur.violation = { name: key, row };
      throw new FieldNotDeclared(`field '${key}' is not in the read set {${cur.readSet}}`);
    },
  });
  const proto = Object.create(guard);
  names.forEach((name, i) => {
    Object.defineProperty(proto, name, {
      get() {
        return cur.rd[i](this[ROW]);
      },
      enumerable: true,
    });
  });
  return { cur, proto };
}

export function row(fn, shape, req, batch, fmt) {
  const { cur, proto } = shape;
  const n = batch.length;
  const out = new Out(fmt, n);
  const w = new Watch(req);
  cur.rd = batch.cols.map(reader);
  cur.violation = null;
  let r = 0;
  const fail = (v) =>
    new UdfError(
      ST.FIELD_NOT_DECLARED,
      `row ${v.row}: read field '${v.name}', which is not in the declared read set {${cur.readSet}}; add it to columns=[...]`,
      { row: v.row },
    );
  try {
    for (; r < n; r++) {
      if (r === w.next) w.check(r);
      const o = Object.create(proto);
      o[ROW] = r;
      const x = fn(o);
      if (cur.violation !== null) throw fail(cur.violation);
      out.set(r, x);
    }
  } catch (e) {
    if (e instanceof FieldNotDeclared && cur.violation !== null) throw fail(cur.violation);
    throw raised(e, r);
  }
  return out.column();
}

// What a user's batch function returned, as an output column of `fmt`: an
// apache-arrow Vector, the typed array of the type, or an array of values.
// The length is the user's; the host checks it against the input.
export function toColumn(x, fmt) {
  if (x instanceof Vector) {
    const n = x.length;
    if (x.data.length === 1 && x.nullCount === 0) {
      const d = x.data[0];
      const Ctor = fmt === 'l' ? BigInt64Array : fmt === 'i' ? Int32Array : Float64Array;
      if (d.values instanceof Ctor) return { fmt, values: d.values.subarray(0, n), validity: null, nullCount: 0 };
    }
    const out = new Out(fmt, n);
    for (let r = 0; r < n; r++) out.set(r, x.get(r));
    return out.column();
  }
  const want = fmt === 'l' ? BigInt64Array : fmt === 'i' ? Int32Array : Float64Array;
  if (x instanceof want) return { fmt, values: x, validity: null, nullCount: 0 };
  if (ArrayBuffer.isView(x) && !(x instanceof DataView))
    throw new UdfError(ST.RETURN_TYPE, `returned a ${x.constructor.name}, not the ${want.name} of the declared type`);
  if (Array.isArray(x)) {
    const out = new Out(fmt, x.length);
    for (let r = 0; r < x.length; r++) out.set(r, x[r]);
    return out.column();
  }
  throw new UdfError(ST.RETURN_TYPE, `returned ${x === null ? 'null' : typeof x}, not a column (a Vector, a ${want.name} or an array)`);
}

// MAP_BATCHES_COLUMN: the user's function once per batch, over Vectors that
// view the request's memory.
export function column(fn, req, batch, fmt) {
  let x;
  try {
    x = fn(...batch.cols.map(toVector));
  } catch (e) {
    throw raised(e, -1);
  }
  return toColumn(x, fmt);
}

export { widthOf };
