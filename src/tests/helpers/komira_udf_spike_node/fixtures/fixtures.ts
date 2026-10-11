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

// Raises on the fourth row it is called for. A per-row function is not told
// its row, so it counts: the corpus opens a fresh context (a fresh evaluation
// of this bundle, so a fresh count) for each case, and every case that uses
// this fixture is one call over one batch. Under PROPAGATE the rows it sees
// are the compacted batch's, which is what the case's expected row relies on.
let rowsSeen = 0;
export function raise_on_row_3(x: bigint): bigint {
  if (rowsSeen++ === 3) throw new Error("raise_on_row_3: row 3");
  return x;
}

// Twelve and sixty-four int64 arguments: a struct and a schema with many
// children. A null in any argument is a null result.
function sumAll(a: Array<bigint | null>): bigint | null {
  let t = 0n;
  for (const v of a) {
    if (v === null) return null;
    t += v;
  }
  return t;
}
export function sum12(...a: Array<bigint | null>): bigint | null {
  return sumAll(a);
}
export function sum64(...a: Array<bigint | null>): bigint | null {
  return sumAll(a);
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

// int64 plus int32, an int64: the compacted batch and the argument schema
// must keep each column's own type.
export function add_mixed(a: bigint | null, b: number | null): bigint | null {
  return a === null || b === null ? null : a + BigInt(b);
}

// Null for 0, else twice the value: a null the function returns for a row
// whose arguments were all valid.
export function null_on_zero(x: bigint): bigint | null {
  return x === 0n ? null : x * 2n;
}

// ---- MAP_BATCHES_COLUMN: one call per batch, over Arrow vectors ---------------

// Each value a relative 5e-10 off, so a result is within the runner's
// tolerance without being equal; 0 stays exactly 0.
export function near(c: Vector<Float64>): Float64Array {
  const out = new Float64Array(c.length);
  for (let i = 0; i < c.length; i++) out[i] = (c.get(i) as number) * (1 + 5e-10);
  return out;
}

// An int64 column as an int32 one, nulls kept.
export function narrow(x: Vector<Int64>): Array<number | null> {
  const out: Array<number | null> = [];
  for (let i = 0; i < x.length; i++) {
    const v = x.get(i);
    out.push(v === null ? null : Number(v));
  }
  return out;
}

// Raises without naming a row: a batch function fails as a whole.
export function raise_no_row(_x: Vector<Int64>): Vector<Int64> {
  throw new Error("raise_no_row: the batch failed");
}

// The corpus runs the identity over a zero-row batch under this name; for
// this runtime it is the ordinary identity.
export const leaf_empty_data_null = identity;

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

// The null count the runtime handed the vector, in every row: the exact
// count of an argument that declared null_count -1 (unknown).
export function null_count_of(x: Vector<Int64>): BigInt64Array {
  return new BigInt64Array(x.length).fill(BigInt(x.nullCount));
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

// Each input batch's column x as a two-column table: x as int64 and
// 10 * x as int32, nulls kept.
export function* table_two_types(input: Iterable<Batch>): Iterable<Array<Array<bigint | number | null>>> {
  for (const [x] of input) {
    const a: Array<bigint | null> = [];
    const b: Array<number | null> = [];
    for (let i = 0; i < x.length; i++) {
      const v = x.get(i);
      a.push(v);
      b.push(v === null ? null : Number(v) * 10);
    }
    yield [a, b];
  }
}

// Yields a one-row table holding 0 before it reads any input, then the
// running sums of the input.
export function* yield_first(input: Iterable<Batch>): Iterable<Array<Array<bigint | null>>> {
  yield [[0n]];
  yield* running_sum(input);
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

// Switches the runtime to its copy path in the middle of a call, as the
// automatic fallback does when a Node refuses external buffers: the arguments
// of this call were wrapped over the engine's memory and must still be
// detached when it ends. The test names the runtime's file in the environment
// (the only test-only channel a fixture has to its own runtime).
declare const process: { env: Record<string, string | undefined> };
declare const require: (id: string) => { setCopyMode(on: boolean): void };
export function switch_to_copy_path(x: bigint): bigint {
  require(process.env.KOMIRA_TEST_RUNTIME_FILE as string).setCopyMode(true);
  return x;
}

export function int32_too_high(_x: number): number {
  return 3000000000;
}

export function int32_too_low(_x: number): number {
  return -3000000000;
}

// The edges themselves are fine: the largest and the smallest int32.
export function int32_edges(x: number): number {
  return x % 2 === 0 ? 2147483647 : -2147483648;
}

export function int64_edges(x: bigint): bigint {
  return x % 2n === 0n ? 2n ** 63n - 1n : -(2n ** 63n);
}

export function int64_too_high(_x: bigint): bigint {
  return 2n ** 63n;
}

export function int64_too_low(_x: bigint): bigint {
  return -(2n ** 63n) - 1n;
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
// Returns an Arrow vector of two chunks (the argument followed by itself).
export function chunked_twice(c: Vector<Float64>): Vector<Float64> {
  return c.concat(c);
}

// 1 for each row if it was handed a typed array (raw), 0 if an Arrow vector.
export const is_typed_array_raw = Object.assign(
  (x: Float64Array | Vector<Float64>): Float64Array => new Float64Array(x.length).fill(x instanceof Float64Array ? 1 : 0),
  { raw: true });

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

// ---- fixtures of this runtime's own tests (cases/, tests/) ---------------------

// Throws null: no message, no stack.
export function throws_null(_x: bigint): bigint {
  throw null;
}

// A number where the declared type is int64: an integer number is converted.
export function number_for_int64(x: bigint): number {
  return Number(x) * 2;
}

// A fractional number where the declared type is int32.
export function float_into_int32(_x: number): number {
  return 0.5;
}

// An aggregate missing two of its four methods.
export const partial_agg = {
  init: (): bigint => 0n,
  update: (s: bigint, _x: bigint | null): bigint => s,
};

// A column function returning an array with several nulls (every third row).
export function nulls_every_third(x: Vector<Int64>): Array<bigint | null> {
  const out: Array<bigint | null> = [];
  for (let i = 0; i < x.length; i++) out.push(i % 3 === 0 ? null : (x.get(i) as bigint) * 2n);
  return out;
}

// A ROW function that returns null when its flag is 0.
export function pick_null(r: Pick): bigint | null {
  return r.flag !== 0n ? r.a : null;
}

// A ROW function that looks at the record the way a debugger or a coercion does.
export function touch_record(r: Pick): bigint {
  return typeof (r as any)[Symbol.iterator] === "undefined" && typeof (r as any)[Symbol.toPrimitive] === "undefined" ? 1n : 0n;
}

// A mergeable aggregate that fails when it is handed a row past the end.
export const sum_checked = {
  init: (): bigint => 0n,
  update: (s: bigint, x: bigint | null): bigint => {
    if (x === undefined) throw new Error("update read a row past the end");
    return x === null ? s : s + x;
  },
  merge: (a: bigint, b: bigint | null): bigint => {
    if (b === undefined) throw new Error("merge read a row past the end");
    return b === null ? a : a + b;
  },
  finish: (s: bigint): bigint => s,
};

// ---- frames of cases/ ---------------------------------------------------------------

// A table whose columns are shorter than its length.
export function* table_ragged(_input: Iterable<Batch>): Iterable<{ length: number; columns: Array<Array<bigint>> }> {
  yield { length: 3, columns: [[1n, 2n]] };
}

// Yields something that is not a table.
export function* yield_number(_input: Iterable<Batch>): Iterable<number> {
  yield 5;
}

// Returns an array of tables, not a generator.
export function frame_array(_input: Iterable<Batch>): Array<Array<Array<bigint>>> {
  return [[[1n]], [[2n]]];
}

// Returns something that is neither an iterator nor an iterable.
export function frame_number(_input: Iterable<Batch>): number {
  return 5;
}

// Reads every input batch before it yields, once: the total.
export function* collect_all(input: Iterable<Batch>): Iterable<Array<Array<bigint>>> {
  let total = 0n;
  for (const [x] of input) for (let i = 0; i < x.length; i++) total += x.get(i) as bigint;
  yield [[total]];
}
