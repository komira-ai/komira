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
