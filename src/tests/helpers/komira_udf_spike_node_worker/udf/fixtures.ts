// The user functions the conformance cases and this runtime's tests load,
// as module-level exports of one TypeScript module that esbuild bundles
// (BUCK, :fixtures_bundle). Each case of komira_udf_spike_abi/cases names a
// fixture by a bare name; the tests load it as `fixtures.mjs#<name>`, and
// each export here does what the case's echo fixture does, in TypeScript.
//
// Types follow the runtime's mapping (design section 6.2): int64 is a
// bigint, float64 a number, null is null. A per-row function takes and
// returns values; a batch function takes apache-arrow Vectors and returns a
// typed array, a Vector or an array. The imports from apache-arrow are
// types only: esbuild drops them, so the bundle carries no Arrow code.

import type { Float64, Int64, RecordBatch, Vector } from 'apache-arrow';

type I64 = bigint | null;
type Table = { numRows?: number; columns: ArrayLike<unknown>[] };

const sleeper = new Int32Array(new SharedArrayBuffer(4));

function sleepMs(ms: number): void {
  Atomics.wait(sleeper, 0, 0, ms);
}

// ---- the shared cases' fixtures ----------------------------------------------

export function double(x: I64): I64 {
  return x === null ? null : 2n * x;
}

export function double_strict(x: bigint): bigint {
  if (x === null) throw new Error('double_strict got a null');
  return 2n * x;
}

export function add_strict(a: bigint, b: bigint): bigint {
  if (a === null || b === null) throw new Error('add_strict got a null');
  return a + b;
}

export function fahrenheit(c: Vector<Float64>): Float64Array {
  const out = new Float64Array(c.length);
  for (let i = 0; i < c.length; i++) out[i] = (c.get(i) ?? NaN) * 1.8 + 32;
  return out;
}

export function identity(x: Vector<Int64>): Vector<Int64> {
  return x;
}

export function short_by_one(x: Vector<Int64>): Array<bigint | null> {
  return x.toArray().slice(0, x.length - 1) as Array<bigint | null>;
}

export function long_by_one(x: Vector<Int64>): Array<bigint | null> {
  const out: Array<bigint | null> = [];
  for (let i = 0; i < x.length; i++) out.push(x.get(i));
  out.push(0n);
  return out;
}

export function null_out(_x: bigint): bigint | null {
  return null;
}

export function raise_on_row_3(x: bigint): bigint {
  if (x === 3n) throw new Error('raise_on_row_3: row 3');
  return x;
}

export function const7(): bigint {
  return 7n;
}

export function slow_loop(x: I64): I64 {
  sleepMs(100);
  return x;
}

export const sum = {
  init: (): bigint => 0n,
  update: (s: bigint, x: I64): bigint => (x === null ? s : s + x),
  merge: (s: bigint, t: I64): bigint => (t === null ? s : s + t),
  finish: (s: bigint): bigint => s,
};

export function* running_sum(batches: Iterable<RecordBatch>): Generator<Table> {
  let total = 0n;
  for (const b of batches) {
    const x = b.getChildAt(0) as Vector<Int64>;
    const out = new BigInt64Array(b.numRows);
    for (let i = 0; i < b.numRows; i++) {
      total += x.get(i) ?? 0n;
      out[i] = total;
    }
    yield { numRows: b.numRows, columns: [out] };
  }
}

export function group_max(values: I64[]): I64 {
  let m: I64 = null;
  for (const v of values) if (v !== null && (m === null || v > m)) m = v;
  return m;
}

export function empty_table(n: bigint): Table {
  return { numRows: Number(n), columns: [] };
}

type PickRow = { flag: bigint | null; a: bigint | null; b: bigint | null };

export function pick(r: PickRow): I64 {
  return r.flag ? r.a : r.b;
}

export function pick_caught(r: PickRow): I64 {
  try {
    return r.flag ? r.a : r.b;
  } catch {
    return 0n;
  }
}

export function* yield_two_then_raise(batches: Iterable<RecordBatch>): Generator<RecordBatch> {
  let n = 0;
  for (const b of batches) {
    if (n === 2) throw new Error('yield_two_then_raise: a third batch');
    n++;
    yield b;
  }
}

export function* endless(_batches: Iterable<RecordBatch>): Generator<Table> {
  for (;;) yield { numRows: 1, columns: [[1n]] };
}

// 2x, and a null for 0: a null the function returns for a valid input.
export function null_on_zero(x: I64): I64 {
  return x === null || x === 0n ? null : 2n * x;
}

// a (int64) + b (int32), null where either is null.
export function add_mixed(a: I64, b: number | null): I64 {
  return a === null || b === null ? null : a + BigInt(b);
}

function sumOrNull(xs: I64[]): I64 {
  let s = 0n;
  for (const x of xs) {
    if (x === null) return null;
    s += x;
  }
  return s;
}

// The sum of twelve and of sixty-four int64 arguments, null where any is.
export function sum12(...xs: I64[]): I64 {
  return sumOrNull(xs);
}

export function sum64(...xs: I64[]): I64 {
  return sumOrNull(xs);
}

// int64 in, the same values as int32 out, nulls kept.
export function narrow(x: Vector<Int64>): Array<number | null> {
  const out: Array<number | null> = [];
  for (let i = 0; i < x.length; i++) {
    const v = x.get(i);
    out.push(v === null ? null : Number(v));
  }
  return out;
}

// x * (1 + 5e-10): within the runner's relative tolerance of 1e-9, and
// exactly 0 for 0.
export function near(x: Vector<Float64>): Float64Array {
  const out = new Float64Array(x.length);
  for (let i = 0; i < x.length; i++) out[i] = (x.get(i) ?? NaN) * (1 + 5e-10);
  return out;
}

// A batch function that raises naming no row.
export function raise_no_row(_x: Vector<Int64>): Vector<Int64> {
  throw new Error('raise_no_row: the batch as a whole');
}

// A one-row table [0] before pulling any input, then running_sum.
export function* yield_first(batches: Iterable<RecordBatch>): Generator<Table> {
  yield { numRows: 1, columns: [[0n]] };
  yield* running_sum(batches);
}

// Each input batch's column as an int64 column and, times ten, an int32
// column, nulls kept.
export function* table_two_types(batches: Iterable<RecordBatch>): Generator<Table> {
  for (const b of batches) {
    const x = b.getChildAt(0) as Vector<Int64>;
    const wide: I64[] = [];
    const small: Array<number | null> = [];
    for (let i = 0; i < b.numRows; i++) {
      const v = x.get(i);
      wide.push(v);
      small.push(v === null ? null : Number(v) * 10);
    }
    yield { numRows: b.numRows, columns: [wide, small] };
  }
}

// ---- this runtime's own cases --------------------------------------------------

// Rows seen by this module in this process: a module global, so each worker
// (each context) counts its own.
let seen = 0n;
export function call_counter(_x: I64): bigint {
  seen += 1n;
  return seen;
}

// Ends the worker process mid-batch, at row 2.
export function exit_on_row_2(x: bigint): bigint {
  if (x === 2n) process.exit(3);
  return x;
}

// Kills the worker with SIGABRT mid-batch.
export function abort_now(_x: I64): I64 {
  process.abort();
}

// A batch function that never returns and checks nothing: only a kill
// stops it.
export function spin_forever(x: Vector<Int64>): Vector<Int64> {
  for (;;) if (x.length < 0) return x;
}

// Spins on the CPU for `ms` milliseconds of wall time per row.
export function spin(ms: bigint): bigint {
  const end = performance.now() + Number(ms);
  while (performance.now() < end) {
    // busy
  }
  return ms;
}

export function returns_float(_x: I64): number {
  return 0.5;
}

export function returns_wrong_array(x: Vector<Float64>): Int32Array {
  return new Int32Array(x.length);
}

export const not_a_function = 42;

export function* not_a_table(_batches: Iterable<RecordBatch>): Generator<number> {
  yield 42;
}

export function* step_rows(n: bigint): Generator<Table> {
  for (let i = 0n; i < n; i++) yield { numRows: 1, columns: [BigInt64Array.of(i)] };
}
