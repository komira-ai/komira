// The adapter's aggregate paths on columns that are slices, called directly
// with hand-built column descriptors (no addon, no engine): the group-id
// column and the value column of aggUpdate and aggMerge, and the group column
// of a plain aggregate, each starting at a non-zero offset behind values that
// would fail or change the answer if read from the start.
//
// What it proves: a mergeable aggregate sums per group when its value and
// group-id columns are sliced (aggUpdate), when its state column and group
// ids are sliced (aggMerge), and a plain aggregate groups by a sliced group
// column and carries a group across a batch boundary.
//
// An emitted group is forgotten and an over-large emit is refused; a raw
// function gets the slice's typed array from its offset; a result vector of
// two chunks is read whole.
//
// Defects caught: a group-id column read from row 0 instead of offset + row
// (aggUpdate, aggMerge), a group column read the same way (plain aggregate).
//
// Also: the group ids against n_groups, a row past the end never read, one
// evaluation of the bundle per context, a symbol read of a ROW record, a ROW's
// and an array result's nulls in the bitmap, the polling of the cancel flag in
// every shape, a step with no literal. Mutants planted (adapter.js): aggUpdate reading idv.vals[row]; aggMerge
// reading idv.vals[row]; nextPlain reading group.vals[r]; aggEmit slicing
// instead of splicing; its over-large check removed; a raw function's
// subarray from 0; a raw function handed vectors; a result read as its first chunk only: each red.
'use strict';

const assert = require('node:assert/strict');
const h = require('./helpers.js');

h.watchdog('adapter units');

// A column descriptor [length, offset, nullCount, validity|null, values]
// whose first `off` slots hold `junk`, as an engine's slice of a longer array.
function col(Type, values, off, junk) {
  const a = new Type(off + values.length);
  a.fill(junk);
  values.forEach((v, i) => { a[off + i] = v; });
  return [values.length, off, 0, null, a.buffer];
}

let interruptedCalls = 0;
let interruptedAnswer = 0;
const native = { interrupted: () => { interruptedCalls++; return interruptedAnswer; }, workerFailed: () => {} };
const adapter = require('./adapter.js').create(native, { codeDir: h.here });
const { SHAPE } = h;
const cols3 = (flags) => [
  col(BigInt64Array, flags, 0, 0n), col(BigInt64Array, flags.map(() => 5n), 0, 0n), col(BigInt64Array, flags.map(() => 6n), 0, 0n),
];

const ctx = adapter.openContext(0)[1];
const open = (spec) => {
  const r = adapter.openInstance(ctx, spec);
  assert.equal(r[0], 0, `open ${spec.entry}: ${r[1]}`);
  return r[1];
};
const column = (r) => {
  assert.equal(r[0], 0, `a failure: ${r[1]}`);
  return Array.from(r[1][1]);
};

// ---- mergeable: update then merge, sliced values and sliced group ids ----
{
  const spec = { entry: 'fixtures.js#sum', shape: SHAPE.AGG_MERGEABLE, args: [['l', 'x']], state: [['l', 's']], result: [['l', 'r']] };
  const g = adapter.aggOpen(open(spec))[1];
  const values = col(BigInt64Array, [10n, 20n, 30n, 40n], 3, -777n);
  const ids = col(Int32Array, [0, 1, 0, 1], 5, 99); // junk 99 is not below n_groups
  assert.deepEqual(adapter.aggUpdate(g, 4, [values], ids, 2), [0], 'update over sliced columns');
  const merged = col(BigInt64Array, [100n, 200n], 2, -555n);
  const mids = col(Int32Array, [1, 0], 7, 99);
  assert.deepEqual(adapter.aggMerge(g, 2, merged, mids, 2), [0], 'merge over sliced columns');
  assert.deepEqual(column(adapter.aggFinish(g, 2)), [240n, 160n], 'per group: 10+30+200 and 20+40+100');
}

// ---- plain: a sliced group column, a group spanning two batches ----
{
  const spec = { entry: 'fixtures.js#group_max', shape: SHAPE.AGG_PLAIN, args: [['l', 'x']], result: [['l', 'r']] };
  const batches = [
    [3, [col(BigInt64Array, [1n, 1n, 2n], 4, 77n), col(BigInt64Array, [5n, 9n, 3n], 2, -1n)]],
    [2, [col(BigInt64Array, [2n, 3n], 3, 88n), col(BigInt64Array, [8n, 4n], 3, -1n)]],
  ];
  let next = 0;
  const f = adapter.frameOpen(open(spec), () => (next < batches.length ? batches[next++] : null))[1];
  const out = [];
  for (let i = 0; i < 4; i++) {
    const r = adapter.frameNext(f);
    assert.equal(r[0], 0, `frameNext: ${r[1]}`);
    if (r[1] === 0) break;
    out.push(...Array.from(r[2][1][0][1]));
  }
  assert.deepEqual(out, [9n, 8n, 4n], 'group 1 max 9, group 2 max 8 (its rows span the batches), group 3 max 4');
}

// ---- emit_first_n: the groups emitted are forgotten, and no more than exist ----
{
  const spec = { entry: 'fixtures.js#sum', shape: SHAPE.AGG_MERGEABLE, args: [['l', 'x']], state: [['l', 's']], result: [['l', 'r']] };
  const g = adapter.aggOpen(open(spec))[1];
  const vals = col(BigInt64Array, [1n, 2n, 3n], 0, 0n);
  assert.deepEqual(adapter.aggUpdate(g, 3, [vals], col(Int32Array, [0, 1, 2], 0, 0), 3), [0]);
  assert.deepEqual(column(adapter.aggState(g, 1)), [1n], 'the first group\'s state');
  assert.deepEqual(column(adapter.aggFinish(g, 2)), [2n, 3n], 'the group emitted is gone: the next two are the rest');
  const over = adapter.aggFinish(g, 1);
  assert.equal(over[0], 15, 'emitting more groups than exist is ERR_INTERNAL');
}

// ---- COLUMN: a raw function over a slice, an Arrow vector of two chunks ----
{
  const colSpec = (entry) => ({ entry, shape: SHAPE.COLUMN, args: [['g', 'x']], result: [['g', 'r']] });
  const slice = col(Float64Array, [1.5, 2.5, 3.5], 4, -9.5);
  const raw = adapter.callBatch(open(colSpec('fixtures.js#identity_raw')), 3, [slice]);
  assert.deepEqual(column(raw), [1.5, 2.5, 3.5], 'a raw function gets the typed array of the slice, from its offset');
  assert.deepEqual(column(adapter.callBatch(open(colSpec('fixtures.js#is_typed_array_raw')), 3, [slice])), [1, 1, 1], 'a raw function is handed typed arrays, not vectors');
  const chunked = adapter.callBatch(open(colSpec('fixtures.js#chunked_twice')), 3, [slice]);
  assert.deepEqual(column(chunked), [1.5, 2.5, 3.5, 1.5, 2.5, 3.5], 'a result vector of two chunks is read whole');
}

// ---- the group ids of an update or a merge are checked against n_groups ----
{
  const spec = { entry: 'fixtures.js#sum', shape: SHAPE.AGG_MERGEABLE, args: [['l', 'x']], state: [['l', 's']], result: [['l', 'r']] };
  const vals = col(BigInt64Array, [1n, 2n], 0, 0n);
  for (const [what, ids] of [['an id equal to n_groups', [0, 2]], ['a negative id', [0, -1]]]) {
    const g = adapter.aggOpen(open(spec))[1];
    const r = adapter.aggUpdate(g, 2, [vals], col(Int32Array, ids, 0, 0), 2);
    assert.equal(r[0], 15, `update with ${what} is ERR_INTERNAL`);
    assert.equal(r[3], 1, `update with ${what} names row 1`);
    const m = adapter.aggMerge(g, 2, col(BigInt64Array, [1n, 2n], 0, 0n), col(Int32Array, ids, 0, 0), 2);
    assert.equal(m[0], 15, `merge with ${what} is ERR_INTERNAL`);
  }
}

// ---- no row past the end is read by an update or a merge ----
{
  const spec = { entry: 'fixtures.js#sum_checked', shape: SHAPE.AGG_MERGEABLE, args: [['l', 'x']], state: [['l', 's']], result: [['l', 'r']] };
  const g = adapter.aggOpen(open(spec))[1];
  assert.deepEqual(adapter.aggUpdate(g, 3, [col(BigInt64Array, [1n, 2n, 3n], 0, 0n)], col(Int32Array, [0, 1, 0], 0, 0), 2), [0], 'update reads exactly its rows');
  assert.deepEqual(adapter.aggMerge(g, 2, col(BigInt64Array, [10n, 20n], 0, 0n), col(Int32Array, [1, 0], 0, 0), 2), [0], 'merge reads exactly its rows');
  assert.deepEqual(column(adapter.aggFinish(g, 2)), [24n, 12n]);
}

// ---- two instances of one context share its evaluation of the bundle ----
{
  const spec = { entry: 'fixtures.js#call_counter', shape: SHAPE.SCALAR, args: [['l', 'x']], result: [['l', 'r']] };
  const a = open(spec);
  const b = open(spec);
  const one = col(BigInt64Array, [0n], 0, 0n);
  assert.deepEqual(Array.from(adapter.callBatch(a, 1, [one])[1][1]), [1n]);
  assert.deepEqual(Array.from(adapter.callBatch(b, 1, [one])[1][1]), [2n], 'a second instance of the context counts on from the first: one evaluation of the bundle per context');
  const other = adapter.openContext(1)[1];
  const c = adapter.openInstance(other, spec)[1];
  assert.deepEqual(Array.from(adapter.callBatch(c, 1, [one])[1][1]), [1n], 'another context has an evaluation of its own');
}

// ---- a ROW record answers a symbol read as undefined; a ROW's nulls reach the bitmap ----
{
  const rowSpec = (entry) => ({ entry, shape: SHAPE.ROW, args: [['l', 'flag'], ['l', 'a'], ['l', 'b']], result: [['l', 'r']] });
  const touched = adapter.callBatch(open(rowSpec('fixtures.js#touch_record')), 2, cols3([1n, 0n]));
  assert.equal(touched[0], 0, `a symbol read is not a field read: ${touched[1]}`);
  assert.deepEqual(Array.from(touched[1][1]), [1n, 1n]);
  const flags = [1n, 0n, 1n, 0n, 0n, 1n, 1n, 1n, 0n, 1n, 1n, 0n];
  const nulls = adapter.callBatch(open(rowSpec('fixtures.js#pick_null')), 12, cols3(flags));
  assert.equal(nulls[0], 0, nulls[1]);
  const valid = Array.from(nulls[1][2]);
  assert.equal(valid.length, 2, 'a validity bitmap of 12 rows is 2 bytes');
  flags.forEach((f, i) => assert.equal((valid[i >> 3] >> (i & 7)) & 1, f !== 0n ? 1 : 0, `row ${i} validity`));
}

// ---- an array result with several nulls keeps each of them ----
{
  const spec = { entry: 'fixtures.js#nulls_every_third', shape: SHAPE.COLUMN, args: [['l', 'x']], result: [['l', 'r']] };
  const r = adapter.callBatch(open(spec), 10, [col(BigInt64Array, [1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n, 9n, 10n], 0, 0n)]);
  assert.equal(r[0], 0, r[1]);
  const valid = Array.from(r[1][2]);
  for (let i = 0; i < 10; i++) assert.equal((valid[i >> 3] >> (i & 7)) & 1, i % 3 === 0 ? 0 : 1, `row ${i} validity`);
}

// ---- the cancel flag is polled at every row of the first 64, then every 64th, in every shape ----
{
  const scalar = { entry: 'fixtures.js#double', shape: SHAPE.SCALAR, args: [['l', 'x']], result: [['l', 'r']] };
  const vals = col(BigInt64Array, new Array(300).fill(1n), 0, 0n);
  interruptedCalls = 0;
  adapter.callBatch(open(scalar), 300, [vals]);
  assert.equal(interruptedCalls, 64 + 4, 'rows 0 to 63, then 64, 128, 192, 256');
  interruptedCalls = 0;
  adapter.callBatch(open({ ...scalar, shape: SHAPE.ROW, entry: 'fixtures.js#pick', args: [['l', 'flag'], ['l', 'a'], ['l', 'b']] }), 300, [vals, vals, vals]);
  assert.equal(interruptedCalls, 64 + 4, 'ROW: the same polling');
  // a stop seen at row 0 ends each shape's call with that status
  interruptedAnswer = 11;
  try {
    assert.equal(adapter.callBatch(open(scalar), 3, [col(BigInt64Array, [1n, 2n, 3n], 0, 0n)])[0], 11, 'SCALAR stops');
    const row = adapter.callBatch(open({ ...scalar, shape: SHAPE.ROW, entry: 'fixtures.js#pick', args: [['l', 'flag'], ['l', 'a'], ['l', 'b']] }), 2, cols3([1n, 0n]));
    assert.equal(row[0], 11, 'ROW stops');
    assert.equal(adapter.callBatch(open({ ...scalar, shape: SHAPE.COLUMN, entry: 'fixtures.js#identity' }), 3, [col(BigInt64Array, [1n, 2n, 3n], 0, 0n)])[0], 11, 'COLUMN stops');
    const agg = { entry: 'fixtures.js#sum', shape: SHAPE.AGG_MERGEABLE, args: [['l', 'x']], state: [['l', 's']], result: [['l', 'r']] };
    const g = adapter.aggOpen(open(agg))[1];
    assert.equal(adapter.aggUpdate(g, 2, [col(BigInt64Array, [1n, 2n], 0, 0n)], col(Int32Array, [0, 0], 0, 0), 1)[0], 11, 'update stops');
    assert.equal(adapter.aggMerge(g, 2, col(BigInt64Array, [1n, 2n], 0, 0n), col(Int32Array, [0, 0], 0, 0), 1)[0], 11, 'merge stops');
    const f = adapter.frameOpen(open({ entry: 'fixtures.js#running_sum', shape: SHAPE.FRAME, args: [['l', 'x']], result: [['l', 'r']] }), () => null)[1];
    assert.equal(adapter.frameNext(f)[0], 11, 'a frame stops');
  } finally {
    interruptedAnswer = 0;
  }
}

// ---- a step with no literal batch is ERR_INTERNAL ----
{
  const step = { entry: 'fixtures.js#empty_table', shape: SHAPE.STEP, args: [['l', 'rows']], result: [] };
  const r = adapter.frameOpen(open(step), () => null);
  assert.equal(r[0], 15, `a step that is given no literal: ${r[1]}`);
}

// ---- a bad value at index 0 of a column result names row 0 ----
{
  const spec = { entry: 'fixtures.js#bad_first', shape: SHAPE.COLUMN, args: [['l', 'x']], result: [['l', 'r']] };
  const r = adapter.callBatch(open(spec), 3, [col(BigInt64Array, [1n, 2n, 3n], 0, 0n)]);
  assert.equal(r[0], 7, `ERR_RETURN_TYPE: ${r[1]}`);
  assert.equal(r[3], 0, 'the error names row 0, not -1');
}

// ---- a duck-typed vector longer than its values is refused ----
{
  const spec = { entry: 'fixtures.js#fake_vector', shape: SHAPE.COLUMN, args: [['l', 'x']], result: [['l', 'r']] };
  const r = adapter.callBatch(open(spec), 3, [col(BigInt64Array, [1n, 2n, 3n], 0, 0n)]);
  assert.equal(r[0], 7, `ERR_RETURN_TYPE, not an over-read: ${r[1]}`);
  assert.ok(String(r[1]).includes('values'), r[1]);
}

// ---- whatever user code throws is a user error ----
{
  const scalar = (entry) => ({ entry, shape: SHAPE.SCALAR, args: [['l', 'x']], result: [['l', 'r']] });
  const one = [col(BigInt64Array, [1n], 0, 0n)];
  const np = adapter.callBatch(open(scalar('fixtures.js#throws_nullproto')), 1, one);
  assert.equal(np[0], 6, `an object with no prototype is ERR_RAISED: ${np[1]}`);
  assert.ok(typeof np[1] === 'string' && np[1].length > 0, 'and has a message');
  const nul = adapter.callBatch(open(scalar('fixtures.js#throws_null')), 1, one);
  assert.equal(nul[0], 6);
  assert.equal(nul[2], null, 'a thrown null has no trace');
}

console.log('adapter units: ok');
