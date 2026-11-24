// The Arrow import end to end: a stand-in producer (tests/arrow_stand_in.c)
// hands komira_addon an Arrow C stream, and readArrowStream
// (src/arrow_import.mts) turns it into an apache-arrow Table of the pinned
// apache-arrow. Each column's bytes are written by hand (tests/arrow_specs.mts),
// so every value read back is the value the bytes hold. A node --test file is
// its own process, so the stand-in's release counts are this file's.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import v8 from 'node:v8';
import vm from 'node:vm';

import { Decimal, Union, UnionMode, type Table } from 'apache-arrow';

import { readArrowStream, type ArrowAddon } from './src/arrow_import.mts';
import { KomiraError, UnsupportedOperation } from './src/errors.mts';
import {
  NULLABLE,
  bitmap,
  fixed,
  streamOf,
  varlen,
  varlenColumn,
  type ArraySpec,
  type SchemaSpec,
  type StreamSpec,
} from './tests/arrow_specs.mts';

const here = import.meta.dirname;
const require = createRequire(import.meta.url);
const addon: ArrowAddon = require(path.join(here, 'komira_addon.node'));
const stand = require(path.join(here, 'arrow_stand_in.node'));

const read = (spec: StreamSpec): Promise<Table> => readArrowStream(addon, stand.stream(spec));

v8.setFlagsFromString('--expose-gc');
const gc = vm.runInNewContext('gc');

// Collect garbage until `done()`, letting the finalizers of Node-API values
// run between collections; a bounded number of rounds, so no clock is read.
async function collect(done: () => boolean, rounds = 200): Promise<void> {
  for (let i = 0; i < rounds && !done(); i++) {
    gc();
    await new Promise((resolve) => setImmediate(resolve));
  }
}

// The values of column `name`, nulls included; rows of nested types as JSON.
function values(table: Table, name: string): unknown[] {
  const column = table.getChild(name);
  assert.ok(column !== null, `no column ${name}`);
  return [...column].map((v) => (v !== null && typeof v === 'object' && typeof v.toJSON === 'function' ? v.toJSON() : v));
}

function typeName(table: Table, name: string): string {
  return String(table.schema.fields.find((f) => f.name === name)?.type);
}

test('integers and floats of every width round-trip, with a null', async () => {
  const valid = [true, false, true];
  const table = await read(
    streamOf([
      [
        fixed('i8', 'c', 3, Int8Array.of(-128, 0, 127), valid),
        fixed('u8', 'C', 3, Uint8Array.of(0, 0, 255), valid),
        fixed('i16', 's', 3, Int16Array.of(-32768, 0, 32767), valid),
        fixed('u16', 'S', 3, Uint16Array.of(0, 0, 65535), valid),
        fixed('i32', 'i', 3, Int32Array.of(-2147483648, 0, 2147483647), valid),
        fixed('u32', 'I', 3, Uint32Array.of(0, 0, 4294967295), valid),
        fixed('i64', 'l', 3, BigInt64Array.of(-(2n ** 63n), 0n, 2n ** 63n - 1n), valid),
        fixed('u64', 'L', 3, BigUint64Array.of(0n, 0n, 2n ** 64n - 1n), valid),
        // Float16 1.0, -2.0 and 65504 (the largest) as their bit patterns.
        fixed('f16', 'e', 3, Uint16Array.of(0x3c00, 0xc000, 0x7bff), valid),
        fixed('f32', 'f', 3, Float32Array.of(1.5, 0, -0.25), valid),
        fixed('f64', 'g', 3, Float64Array.of(Number.MAX_VALUE, 0, -Number.MIN_VALUE), valid),
      ],
    ]),
  );
  assert.equal(table.numRows, 3);
  const want: Record<string, [string, unknown[]]> = {
    i8: ['Int8', [-128, null, 127]],
    u8: ['Uint8', [0, null, 255]],
    i16: ['Int16', [-32768, null, 32767]],
    u16: ['Uint16', [0, null, 65535]],
    i32: ['Int32', [-2147483648, null, 2147483647]],
    u32: ['Uint32', [0, null, 4294967295]],
    i64: ['Int64', [-(2n ** 63n), null, 2n ** 63n - 1n]],
    u64: ['Uint64', [0n, null, 2n ** 64n - 1n]],
    f16: ['Float16', [1, null, 65504]],
    f32: ['Float32', [1.5, null, -0.25]],
    f64: ['Float64', [Number.MAX_VALUE, null, -Number.MIN_VALUE]],
  };
  for (const [name, [type, expected]] of Object.entries(want)) {
    assert.equal(typeName(table, name), type, name);
    assert.deepEqual(values(table, name), expected, name);
    assert.equal(table.getChild(name)?.nullCount, 1, name);
  }
});

test('bool round-trips with nulls, over two batches', async () => {
  const table = await read(
    streamOf([
      [fixed('b', 'b', 3, bitmap([true, false, true]), [true, true, false])],
      // Nine slots: the values cross a byte boundary.
      [fixed('b', 'b', 9, bitmap([false, true, false, false, true, true, false, false, true]))],
    ]),
  );
  assert.equal(typeName(table, 'b'), 'Bool');
  assert.deepEqual(values(table, 'b'), [true, false, null, false, true, false, false, true, true, false, false, true]);
});

test('dates, times, timestamps, durations and intervals round-trip', async () => {
  const table = await read(
    streamOf([
      [
        fixed('d32', 'tdD', 2, Int32Array.of(0, 19000), [true, false]),
        fixed('d64', 'tdm', 2, BigInt64Array.of(-86400000n, 86400000n)),
        fixed('t_s', 'tts', 2, Int32Array.of(1, 86399)),
        fixed('t_ms', 'ttm', 2, Int32Array.of(1, 86399999)),
        fixed('t_us', 'ttu', 2, BigInt64Array.of(1n, 86399999999n)),
        fixed('t_ns', 'ttn', 2, BigInt64Array.of(1n, 86399999999999n)),
        fixed('ts_s', 'tss:', 2, BigInt64Array.of(-1n, 1700000000n)),
        fixed('ts_ms', 'tsm:Europe/Oslo', 2, BigInt64Array.of(0n, 1700000000123n)),
        fixed('ts_us', 'tsu:UTC', 2, BigInt64Array.of(1000n, 1700000000123000n)),
        fixed('ts_ns', 'tsn:+05:30', 2, BigInt64Array.of(1000000n, 1700000000123000000n)),
        fixed('dur_s', 'tDs', 2, BigInt64Array.of(-5n, 5n)),
        fixed('dur_ms', 'tDm', 2, BigInt64Array.of(-5n, 5n)),
        fixed('dur_us', 'tDu', 2, BigInt64Array.of(-5n, 5n)),
        fixed('dur_ns', 'tDn', 2, BigInt64Array.of(-5n, 5n)),
        fixed('iv_ym', 'tiM', 2, Int32Array.of(14, -1)),
        fixed('iv_dt', 'tiD', 2, Int32Array.of(1, 500, -2, 600)),
        // Months, days, then the nanoseconds as an int64 (low word first).
        fixed('iv_mdn', 'tin', 2, Int32Array.of(1, 2, 3, 0, -1, -2, -3, -1)),
      ],
    ]),
  );
  const want: Record<string, [string, unknown[]]> = {
    d32: ['Date32<DAY>', [0, null]],
    d64: ['Date64<MILLISECOND>', [-86400000, 86400000]],
    t_s: ['Time32<SECOND>', [1, 86399]],
    t_ms: ['Time32<MILLISECOND>', [1, 86399999]],
    t_us: ['Time64<MICROSECOND>', [1n, 86399999999n]],
    t_ns: ['Time64<NANOSECOND>', [1n, 86399999999999n]],
    // apache-arrow reads a timestamp as milliseconds.
    ts_s: ['Timestamp<SECOND>', [-1000, 1700000000000]],
    ts_ms: ['Timestamp<MILLISECOND, Europe/Oslo>', [0, 1700000000123]],
    ts_us: ['Timestamp<MICROSECOND, UTC>', [1, 1700000000123]],
    ts_ns: ['Timestamp<NANOSECOND, +05:30>', [1, 1700000000123]],
    dur_s: ['Duration<SECOND>', [-5n, 5n]],
    dur_ms: ['Duration<MILLISECOND>', [-5n, 5n]],
    dur_us: ['Duration<MICROSECOND>', [-5n, 5n]],
    dur_ns: ['Duration<NANOSECOND>', [-5n, 5n]],
    iv_ym: ['Interval<YEAR_MONTH>', [Int32Array.of(1, 2), Int32Array.of(0, -1)]],
    iv_dt: ['Interval<DAY_TIME>', [Int32Array.of(1, 500), Int32Array.of(-2, 600)]],
    iv_mdn: ['Interval<MONTH_DAY_NANO>', [Int32Array.of(1, 2, 3, 0), Int32Array.of(-1, -2, -3, -1)]],
  };
  for (const [name, [type, expected]] of Object.entries(want)) {
    assert.equal(typeName(table, name), type, name);
    assert.deepEqual(values(table, name), expected, name);
  }
});

test('decimal128 and decimal256 round-trip with their precision, scale and width', async () => {
  // Little-endian two's complement words: 12345, -1 and 2^64 as 128-bit
  // values, and 7, -1 and 2^128 as 256-bit values.
  const ones = (n: number) => Array(n).fill(0xffffffff);
  const d256 = [7, 0, 0, 0, 0, 0, 0, 0, ...ones(8), 0, 0, 0, 0, 1, 0, 0, 0];
  const table = await read(
    streamOf([
      [
        fixed('d128', 'd:10,2', 3, Uint32Array.of(12345, 0, 0, 0, ...ones(4), 0, 0, 1, 0), [true, true, true]),
        fixed('d128w', 'd:38,0,128', 3, Uint32Array.of(1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0), [true, false, true]),
        fixed('d256', 'd:76,5,256', 3, Uint32Array.from(d256)),
      ],
    ]),
  );
  const decimal = (name: string) => table.schema.fields.find((f) => f.name === name)?.type as Decimal;
  assert.deepEqual([decimal('d128').precision, decimal('d128').scale, decimal('d128').bitWidth], [10, 2, 128]);
  assert.deepEqual([decimal('d128w').precision, decimal('d128w').scale, decimal('d128w').bitWidth], [38, 0, 128]);
  assert.deepEqual([decimal('d256').precision, decimal('d256').scale, decimal('d256').bitWidth], [76, 5, 256]);
  // A decimal value's text is its unscaled integer.
  const text = (name: string) => [...(table.getChild(name) ?? [])].map((v) => (v === null ? null : String(v)));
  assert.deepEqual(text('d128'), ['12345', '-1', '18446744073709551616']);
  assert.deepEqual(text('d128w'), ['1', null, '2']);
  // The 256-bit values as their words: apache-arrow 21.2.0 prints a value
  // wider than 128 bits wrongly (2^128 as "6"), but holds its words.
  const words = [...(table.getChild('d256') ?? [])].map((v) => Array.from(v as Uint32Array));
  assert.deepEqual(words, [d256.slice(0, 8), d256.slice(8, 16), d256.slice(16, 24)]);
});

test('utf8, binary, large utf8 and large binary round-trip, with an empty value and a null', async () => {
  const bin = (...b: number[]) => Uint8Array.of(...b);
  const table = await read(
    streamOf([
      [
        varlenColumn('s', 'u', ['oslo', '', null, 'smörgåsbord']),
        varlenColumn('b', 'z', [bin(0, 255), bin(), null, bin(1)]),
        varlenColumn('ls', 'U', ['a', null, '', 'ünïcode']),
        varlenColumn('lb', 'Z', [null, bin(7, 7), bin(), bin(0)]),
      ],
    ]),
  );
  assert.deepEqual(
    ['s', 'b', 'ls', 'lb'].map((n) => typeName(table, n)),
    ['Utf8', 'Binary', 'LargeUtf8', 'LargeBinary'],
  );
  assert.deepEqual(values(table, 's'), ['oslo', '', null, 'smörgåsbord']);
  assert.deepEqual(values(table, 'b'), [bin(0, 255), bin(), null, bin(1)]);
  assert.deepEqual(values(table, 'ls'), ['a', null, '', 'ünïcode']);
  assert.deepEqual(values(table, 'lb'), [null, bin(7, 7), bin(), bin(0)]);
});

// A dictionary column whose two batches share the dictionary's memory (the
// pool), as an exporter that shares buffers between batches hands them out.
function dictionaryStream(): StreamSpec {
  const [offsets, data] = varlen(['red', 'green'], false);
  const column = (indices: Int32Array, valid: boolean[] | null) => ({
    schema: { format: 'i', name: 'colour', flags: NULLABLE, dictionary: { format: 'u', flags: NULLABLE } },
    array: {
      length: indices.length,
      nullCount: valid === null ? 0 : valid.filter((v) => !v).length,
      buffers: [valid === null ? null : bitmap(valid), indices],
      dictionary: { length: 2, buffers: [null, 0, 1] },
    },
  });
  return streamOf([[column(Int32Array.of(1, 0, 0, 1), [true, true, false, true])], [column(Int32Array.of(0), null)]], {
    pool: [offsets, data],
  });
}

test('a dictionary of utf8 values round-trips, its memory shared by two batches', async () => {
  const table = await read(dictionaryStream());
  assert.equal(typeName(table, 'colour'), 'Dictionary<Int32, Utf8>');
  assert.deepEqual(values(table, 'colour'), ['green', 'red', null, 'green', 'red']);
  assert.equal(table.batches.length, 2);
});

// list<int32>, struct<a: int32, b: utf8>, map<utf8, int64>, and sparse and
// dense unions of int32 and utf8, each with a null or an empty value.
function nestedColumns(): { schema: SchemaSpec; array: ArraySpec }[] {
  const [sOffsets, sData] = varlen(['x', null, null], false);
  const [kOffsets, kData] = varlen(['k1', 'k2'], false);
  const [uOffsets, uData] = varlen(['', 'u', ''], false);
  const [dOffsets, dData] = varlen(['u'], false);
  const int32 = { format: 'i', name: 'i', flags: NULLABLE };
  const utf8 = { format: 'u', name: 's', flags: NULLABLE };
  return [
    {
      schema: { format: '+l', name: 'list', flags: NULLABLE, children: [{ format: 'i', name: 'item', flags: NULLABLE }] },
      array: {
        length: 3,
        nullCount: 1,
        buffers: [bitmap([true, false, true]), Int32Array.of(0, 2, 2, 2)],
        children: [{ length: 2, buffers: [null, Int32Array.of(1, 2)] }],
      },
    },
    {
      schema: {
        format: '+s',
        name: 'struct',
        flags: NULLABLE,
        children: [
          { format: 'i', name: 'a', flags: NULLABLE },
          { format: 'u', name: 'b', flags: NULLABLE },
        ],
      },
      array: {
        length: 3,
        nullCount: 1,
        buffers: [bitmap([true, false, true])],
        children: [
          { length: 3, buffers: [null, Int32Array.of(1, 0, 3)] },
          { length: 3, nullCount: 2, buffers: [bitmap([true, false, false]), sOffsets, sData] },
        ],
      },
    },
    {
      schema: {
        format: '+m',
        name: 'map',
        flags: NULLABLE,
        children: [
          {
            format: '+s',
            name: 'entries',
            children: [
              { format: 'u', name: 'key' },
              { format: 'l', name: 'value', flags: NULLABLE },
            ],
          },
        ],
      },
      array: {
        length: 3,
        nullCount: 1,
        buffers: [bitmap([true, true, false]), Int32Array.of(0, 2, 2, 2)],
        children: [
          {
            length: 2,
            buffers: [null],
            children: [
              { length: 2, buffers: [null, kOffsets, kData] },
              { length: 2, buffers: [null, BigInt64Array.of(1n, 2n)] },
            ],
          },
        ],
      },
    },
    {
      schema: { format: '+us:0,1', name: 'sparse', children: [int32, utf8] },
      array: {
        length: 3,
        buffers: [Int8Array.of(0, 1, 0)],
        children: [
          { length: 3, buffers: [null, Int32Array.of(7, 0, 9)] },
          { length: 3, buffers: [null, uOffsets, uData] },
        ],
      },
    },
    {
      // Type ids that are not the child indexes.
      schema: { format: '+ud:3,5', name: 'dense', children: [int32, utf8] },
      array: {
        length: 3,
        buffers: [Int8Array.of(3, 5, 3), Int32Array.of(0, 0, 1)],
        children: [
          { length: 2, buffers: [null, Int32Array.of(7, 9)] },
          { length: 1, buffers: [null, dOffsets, dData] },
        ],
      },
    },
  ];
}

test('list, struct, map, sparse union and dense union round-trip, with nulls', async () => {
  const table = await read(streamOf([nestedColumns()]));
  assert.deepEqual(
    ['list', 'struct', 'map', 'sparse', 'dense'].map((n) => typeName(table, n)),
    [
      'List<Int32>',
      'Struct<{a:Int32, b:Utf8}>',
      'Map<{key:Utf8, value:Int64}>',
      'Union<Int32 | Utf8>',
      'Union<Int32 | Utf8>',
    ],
  );
  const union = (name: string) => table.schema.fields.find((f) => f.name === name)?.type as Union;
  assert.deepEqual([union('sparse').mode, [...union('sparse').typeIds]], [UnionMode.Sparse, [0, 1]]);
  assert.deepEqual([union('dense').mode, [...union('dense').typeIds]], [UnionMode.Dense, [3, 5]]);
  assert.deepEqual(values(table, 'list'), [[1, 2], null, []]);
  assert.deepEqual(values(table, 'struct'), [{ a: 1, b: 'x' }, null, { a: 3, b: null }]);
  assert.deepEqual(values(table, 'map'), [{ k1: 1n, k2: 2n }, {}, null]);
  assert.deepEqual(values(table, 'sparse'), [7, 'u', 9]);
  assert.deepEqual(values(table, 'dense'), [7, 'u', 9]);
});

test('arrays with an offset are read from that slot, in every kind of column and in the batch', async () => {
  const [sOffsets, sData] = varlen(['zz', 'zz', 'a', 'bc', ''], false);
  const [uOffsets, uData] = varlen(['', '', 'u', ''], false);
  const int32 = { format: 'i', name: 'i', flags: NULLABLE };
  const utf8 = { format: 'u', name: 's', flags: NULLABLE };
  const columns: { schema: SchemaSpec; array: ArraySpec }[] = [
    {
      schema: { format: 'i', name: 'int', flags: NULLABLE },
      array: { length: 3, offset: 2, nullCount: 1, buffers: [bitmap([false, false, true, false, true]), Int32Array.of(9, 9, 1, 2, 3)] },
    },
    {
      // Offset 10: the first value is bit 2 of the second byte.
      schema: { format: 'b', name: 'bool', flags: NULLABLE },
      array: {
        length: 3,
        offset: 10,
        buffers: [null, bitmap([...Array(10).fill(false), true, false, true])],
      },
    },
    {
      schema: { format: 'u', name: 'utf8', flags: NULLABLE },
      array: { length: 3, offset: 2, buffers: [null, sOffsets, sData] },
    },
    {
      schema: { format: '+l', name: 'list', flags: NULLABLE, children: [{ format: 'i', name: 'item' }] },
      array: {
        length: 3,
        offset: 1,
        buffers: [null, Int32Array.of(0, 1, 3, 3, 4)],
        children: [{ length: 4, buffers: [null, Int32Array.of(0, 1, 2, 3)] }],
      },
    },
    {
      // A struct at offset 1 whose child is at offset 1 too: row i is the
      // child's slot 1 + 1 + i.
      schema: { format: '+s', name: 'struct', flags: NULLABLE, children: [{ format: 'i', name: 'a' }] },
      array: {
        length: 3,
        offset: 1,
        buffers: [null],
        children: [{ length: 4, offset: 1, buffers: [null, Int32Array.of(-1, -1, 1, 2, 3)] }],
      },
    },
    {
      schema: { format: 'c', name: 'dict', flags: NULLABLE, dictionary: { format: 'u' } },
      array: {
        length: 3,
        offset: 2,
        buffers: [null, Int8Array.of(0, 0, 1, 0, 1)],
        dictionary: { length: 2, buffers: [null, ...varlen(['p', 'q'], false)] },
      },
    },
    {
      schema: { format: '+us:0,1', name: 'sparse', children: [int32, utf8] },
      array: {
        length: 3,
        offset: 1,
        buffers: [Int8Array.of(0, 0, 1, 0)],
        children: [
          { length: 4, buffers: [null, Int32Array.of(6, 7, 0, 9)] },
          { length: 4, buffers: [null, uOffsets, uData] },
        ],
      },
    },
    {
      schema: { format: '+ud:3,5', name: 'dense', children: [int32, utf8] },
      array: {
        length: 3,
        offset: 1,
        buffers: [Int8Array.of(3, 3, 5, 3), Int32Array.of(0, 1, 0, 2)],
        children: [
          { length: 3, buffers: [null, Int32Array.of(7, 8, 9)] },
          { length: 1, buffers: [null, ...varlen(['u'], false)] },
        ],
      },
    },
  ];
  const table = await read(streamOf([columns]));
  assert.deepEqual(values(table, 'int'), [1, null, 3]);
  assert.deepEqual(values(table, 'bool'), [true, false, true]);
  assert.deepEqual(values(table, 'utf8'), ['a', 'bc', '']);
  assert.deepEqual(values(table, 'list'), [[1, 2], [], [3]]);
  assert.deepEqual(values(table, 'struct'), [{ a: 1 }, { a: 2 }, { a: 3 }]);
  assert.deepEqual(values(table, 'dict'), ['q', 'p', 'q']);
  assert.deepEqual(values(table, 'sparse'), [7, 'u', 9]);
  assert.deepEqual(values(table, 'dense'), [8, 'u', 9]);

  // The batch itself at offset 1: its columns are read from their slot 1.
  const shifted = streamOf([[fixed('n', 'i', 4, Int32Array.of(1, 2, 3, 4))]]);
  shifted.batches[0] = { ...shifted.batches[0], length: 3, offset: 1 };
  assert.deepEqual(values(await read(shifted), 'n'), [2, 3, 4]);
});

test('names, nullability and the schema and field metadata carry over', async () => {
  const spec = streamOf([[fixed('n', 'i', 1, Int32Array.of(5)), fixed('m', 'i', 1, Int32Array.of(6))]], {});
  spec.schema.metadata = [['origin', 'stand-in'], ['empty', '']];
  spec.schema.children = [
    { format: 'i', name: 'n', flags: 0, metadata: [['unit', 'm']] },
    { format: 'i', name: 'm', flags: NULLABLE },
  ];
  const table = await read(spec);
  assert.deepEqual([...table.schema.metadata], [['origin', 'stand-in'], ['empty', '']]);
  const [n, m] = table.schema.fields;
  assert.deepEqual([n.name, n.nullable, [...n.metadata]], ['n', false, [['unit', 'm']]]);
  assert.deepEqual([m.name, m.nullable, [...m.metadata]], ['m', true, []]);
});

test('every dictionary index of up to 32 bits reads its values', async () => {
  const indices: [string, ArrayBufferView][] = [
    ['c', Int8Array.of(1, 0)],
    ['C', Uint8Array.of(1, 0)],
    ['s', Int16Array.of(1, 0)],
    ['S', Uint16Array.of(1, 0)],
    ['i', Int32Array.of(1, 0)],
    ['I', Uint32Array.of(1, 0)],
  ];
  const table = await read(
    streamOf([
      indices.map(([format, data]) => ({
        schema: { format, name: `d_${format}`, dictionary: { format: 'u' } },
        array: { length: 2, buffers: [null, data], dictionary: { length: 2, buffers: [null, ...varlen(['p', 'q'], false)] } },
      })),
    ]),
  );
  for (const [format] of indices) assert.deepEqual(values(table, `d_${format}`), ['q', 'p'], format);
});

test('a utf8 column of empty values may leave its data buffer NULL', async () => {
  const table = await read(
    streamOf([[{ schema: { format: 'u', name: 's' }, array: { length: 3, buffers: [null, Int32Array.of(0, 0, 0, 0), null] } }]]),
  );
  assert.deepEqual(values(table, 's'), ['', '', '']);
});

test('a table that was read holds its batches until it is collected, and the stream and schema are released', async () => {
  const capsule = stand.stream(streamOf([[fixed('n', 'i', 2, Int32Array.of(1, 2))], [fixed('n', 'i', 1, Int32Array.of(3))]]));
  let table: Table | null = await readArrowStream(addon, capsule);
  assert.deepEqual(values(table, 'n'), [1, 2, 3]);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 0, bad: 0 });
  table = null;
  await collect(() => released(capsule).arrays >= 2);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('a stream with no batch is a table of its schema with no rows', async () => {
  const table = await read({
    schema: {
      format: '+s',
      children: [
        { format: 'l', name: 'id' },
        { format: 'u', name: 'label', flags: NULLABLE },
      ],
    },
    batches: [],
  });
  assert.equal(table.numRows, 0);
  assert.equal(table.batches.length, 0);
  assert.deepEqual(
    table.schema.fields.map((f) => `${f.name}:${f.type}`),
    ['id:Int64', 'label:Utf8'],
  );
});

test('a batch of no rows may leave every buffer NULL', async () => {
  const table = await read(
    streamOf([
      [
        { schema: { format: 'i', name: 'n' }, array: { length: 0, buffers: [null, null] } },
        { schema: { format: 'u', name: 's' }, array: { length: 0, buffers: [null, null, null] } },
      ],
    ]),
  );
  assert.equal(table.numRows, 0);
  assert.equal(table.batches.length, 1);
  assert.deepEqual(values(table, 'n'), []);
  assert.deepEqual(values(table, 's'), []);
});

// The stand-in's release counts of the stream of `capsule`.
function released(capsule: unknown) {
  const c = stand.counts(capsule);
  return { streams: c.streamReleases, schemas: c.schemaReleases, arrays: c.arrayReleases, bad: c.badReleases };
}

test('a format the mapping does not know is refused, naming the column and the format', async () => {
  const cases: [SchemaSpec, string][] = [
    [{ format: 'w:4', name: 'hash' }, 'column "hash": Arrow format "w:4" is not supported'],
    [{ format: 'n', name: 'nothing' }, 'column "nothing": Arrow format "n" is not supported'],
    [{ format: 'vu', name: 'view' }, 'column "view": Arrow format "vu" is not supported'],
    [{ format: 'd:10,2,64', name: 'd64' }, 'column "d64": Arrow format "d:10,2,64" is not supported'],
    [{ format: 'd:10', name: 'd' }, 'column "d": Arrow format "d:10" is not supported'],
    [{ format: 'tsx:', name: 'ts' }, 'column "ts": Arrow format "tsx:" is not supported'],
    [{ format: '+us:0', name: 'u', children: [] }, 'column "u": Arrow format "+us:0" is not supported'],
    [
      { format: '+w:2', name: 'pairs', children: [{ format: 'i', name: 'item' }] },
      'column "pairs": Arrow format "+w:2" is not supported',
    ],
    [
      { format: '+s', name: 'outer', children: [{ format: 'i', name: 'ok' }, { format: 'vz', name: 'inner' }] },
      'column "outer.inner": Arrow format "vz" is not supported',
    ],
    [
      { format: 'g', name: 'dict', dictionary: { format: 'u' } },
      'column "dict": Arrow format "g" is not supported',
    ],
    [{ format: 'l', name: 'dict64', dictionary: { format: 'u' } }, 'column "dict64": Arrow format "l" is not supported'],
    [{ format: 'L', name: 'dictu64', dictionary: { format: 'u' } }, 'column "dictu64": Arrow format "L" is not supported'],
    [
      { format: '+m', name: 'm', children: [{ format: 'i', name: 'entries' }] },
      'column "m": Arrow format "+m" is not supported',
    ],
  ];
  for (const [schema, message] of cases) {
    // The batch is never read, so its buffers are not checked against the format.
    const capsule = stand.stream({ schema: { format: '+s', children: [schema] }, batches: [{ length: 0, buffers: [null] }] });
    await assert.rejects(readArrowStream(addon, capsule), (err: unknown) => {
      assert.ok(err instanceof UnsupportedOperation, String(err));
      assert.ok(err instanceof KomiraError);
      assert.equal(err.name, 'UnsupportedOperation');
      assert.equal(err.message, message);
      assert.deepEqual([err.status, err.code, err.step], [null, null, null]);
      return true;
    });
    // Nothing was handed to JavaScript, so the refusal releases everything at once.
    assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 1, bad: 0 });
  }
});

test('a failing get_next rejects readArrowStream with the get_last_error text', async () => {
  const spec = streamOf([[fixed('n', 'i', 1, Int32Array.of(1))]], {
    nextError: { at: 1, status: 5, message: 'stand-in: batch 2 cannot be read' },
  });
  await assert.rejects(read(spec), {
    code: 'KOMIRA_ARROW_STREAM',
    status: 5,
    lastError: 'stand-in: batch 2 cannot be read',
    message: 'get_next failed (status 5): stand-in: batch 2 cannot be read',
  });
});

test('the pinned apache-arrow the tests run satisfies the package peer range ^21.2.0', () => {
  const pkg = JSON.parse(readFileSync(path.join(here, 'package.json'), 'utf8'));
  assert.deepEqual(pkg.peerDependencies, { 'apache-arrow': '^21.2.0' });
  const arrow = JSON.parse(readFileSync(path.join(here, 'node_modules', 'apache-arrow', 'package.json'), 'utf8'));
  const [major, minor] = arrow.version.split('.').map(Number);
  assert.ok(major === 21 && minor >= 2, `apache-arrow ${arrow.version} is outside ^21.2.0`);
});
