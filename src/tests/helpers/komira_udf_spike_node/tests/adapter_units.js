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
// Mutants planted (adapter.js): aggUpdate reading idv.vals[row]; aggMerge
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

const native = { interrupted: () => 0, workerFailed: () => {} };
const adapter = require('./adapter.js').create(native, { codeDir: h.here });
const { SHAPE } = h;

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

console.log('adapter units: ok');
