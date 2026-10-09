// User code for the Node runtime, as a user writes it: plain TypeScript
// functions with no decorator, no import of the runtime and no bundled
// dependency. The conformance cases of komira_udf_spike_abi name their
// fixtures by bare name; each function here does what the case expects.
// apache-arrow is imported for its types only (erased by esbuild); at run
// time it is the base image's package, which the runtime loads.
//
// The result type is not written here. TypeScript's types do not exist at run
// time, so the plan's declared type (the verb's) is the only declaration, and
// a function returns what that type maps to: bigint for int64, number for
// float64 and int32, null for a null.
import { threadId } from "node:worker_threads";
import type { Float64, Int64, Vector } from "apache-arrow";

// ---- SCALAR: one call per row ------------------------------------------------

export function double(x: bigint | null): bigint | null {
  return x === null ? null : 2n * x;
}

export function double_strict(x: bigint | null): bigint {
  if (x === null) throw new Error("double_strict got a null");
  return 2n * x;
}

export function add_strict(a: bigint | null, b: bigint | null): bigint {
  if (a === null || b === null) throw new Error("add_strict got a null");
  return a + b;
}

export function raise_on_row_3(x: bigint): bigint {
  if (x === 3n) throw new Error("raise_on_row_3: row 3");
  return x;
}

export function const7(): bigint {
  return 7n;
}

export function null_out(_x: bigint): bigint | null {
  return null;
}

// A slow row: waits 100 ms by the clock. The runtime checks the cancel flag
// and the deadline between rows, never inside one.
export function slow_loop(x: bigint): bigint {
  const until = performance.now() + 100;
  while (performance.now() < until) {
    // wait
  }
  return x;
}

// ---- MAP_BATCHES_COLUMN: one call per batch, over Arrow vectors ---------------

export function fahrenheit(c: Vector<Float64>): Float64Array {
  const out = new Float64Array(c.length);
  for (let i = 0; i < c.length; i++) out[i] = (c.get(i) as number) * 1.8 + 32;
  return out;
}

export function identity(x: Vector<Int64>): Vector<Int64> {
  return x;
}

export function short_by_one(x: Vector<Int64>): Vector<Int64> {
  return x.slice(0, x.length - 1);
}

export function long_by_one(x: Vector<Int64>): BigInt64Array {
  const out = new BigInt64Array(x.length + 1);
  out.set(x.toArray());
  return out;
}

// ---- ROW: a record of the declared fields -------------------------------------

type Pick = { flag: bigint; a: bigint; b: bigint };

export function pick(r: Pick): bigint {
  return r.flag !== 0n ? r.a : r.b;
}

// The same, where the function catches whatever the read throws.
export function pick_caught(r: Pick): bigint {
  try {
    return r.flag !== 0n ? r.a : r.b;
  } catch {
    return 0n;
  }
}

// ---- aggregates ----------------------------------------------------------------

// Mergeable: a state per group, an int64 here.
export const sum = {
  init: (): bigint => 0n,
  update: (s: bigint, x: bigint | null): bigint => (x === null ? s : s + x),
  merge: (a: bigint, b: bigint | null): bigint => (b === null ? a : a + b),
  finish: (s: bigint): bigint => s,
};

// Plain: once per group, over the group's values.
export function group_max(values: Array<bigint | null>): bigint {
  let max: bigint | null = null;
  for (const v of values) if (v !== null && (max === null || v > max)) max = v;
  return max as bigint;
}

// ---- frames: generators over batches --------------------------------------------

type Batch = Vector<Int64>[];

export function* running_sum(input: Iterable<Batch>): Iterable<Array<Array<bigint | null>>> {
  let running = 0n;
  for (const [x] of input) {
    const out: Array<bigint | null> = [];
    for (let i = 0; i < x.length; i++) {
      const v = x.get(i);
      if (v === null) {
        out.push(null);
      } else {
        running += v;
        out.push(running);
      }
    }
    yield [out];
  }
}

// Yields its first two input batches unchanged, then raises, the rest unread.
export function* yield_two_then_raise(input: Iterable<Batch>): Iterable<Batch> {
  let n = 0;
  for (const b of input) {
    yield b;
    if (++n === 2) throw new Error("yield_two_then_raise: raised after two outputs");
  }
}

// Never ends.
export function* endless(_input: Iterable<Batch>): Iterable<Array<bigint[]>> {
  while (true) yield [[0n]];
}

// A step: a table with `rows` rows and no columns.
export function* empty_table(rows: bigint): Iterable<{ length: number; columns: [] }> {
  yield { length: Number(rows), columns: [] };
}

// ---- functions that return what their declared type does not allow ---------------

export function float_into_int(_x: bigint): number {
  return 0.5;
}

export function returns_string(_x: number): string {
  return "not a number";
}

export function throws_string(_x: bigint): bigint {
  throw "a thrown string, not an Error";
}

export function wrong_array(x: Vector<Int64>): Float64Array {
  return new Float64Array(x.length);
}

// ---- the benchmarks' and tests' own functions -----------------------------------

export function fahrenheit_rows(c: number): number {
  return c * 1.8 + 32;
}

export function fahrenheit_batch(c: Vector<Float64>): Float64Array {
  const x = c.toArray();
  const out = new Float64Array(x.length);
  for (let i = 0; i < x.length; i++) out[i] = x[i] * 1.8 + 32;
  return out;
}

// The boundary alone: the typed array goes back as it came, with no Arrow
// vector built (a function marked raw gets typed arrays).
export const identity_raw = Object.assign((x: Float64Array): Float64Array => x, { raw: true });

export function identity_rows(x: number): number {
  return x;
}

// Module-level state: each context evaluates the bundle afresh, so each counts
// from 1.
let calls = 0n;
export function call_counter(_x: bigint): bigint {
  calls += 1n;
  return calls;
}

// Which worker_threads thread (0: the main thread) runs this context.
export function thread_id(_x: bigint): bigint {
  return BigInt(threadId);
}

// Spins on this thread's CPU for `ms` milliseconds.
export function spin(ms: number): number {
  const until = performance.now() + ms;
  while (performance.now() < until) {
    // spin
  }
  return ms;
}

// One long row, no check inside it: a cancel set meanwhile is seen only
// after the row.
export function busy(x: bigint): bigint {
  const until = performance.now() + 300;
  while (performance.now() < until) {
    // spin
  }
  return x;
}

// A row that never returns.
export function forever(x: bigint): bigint {
  for (;;) {
    // never
  }
  return x;
}

// Keeps the values of the previous batch, to see what its view holds once
// the call that carried it has ended: every row of the result is -1 on the
// first call, then the length of the view kept from the call before.
let kept: Float64Array | null = null;
export function remember(c: Vector<Float64>): Float64Array {
  const previous = kept === null ? -1 : kept.length;
  kept = c.toArray();
  return new Float64Array(c.length).fill(previous);
}
