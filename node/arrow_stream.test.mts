// The addon's half of the Arrow import (arrow_import.c), called directly: the
// drain of an Arrow C stream, the descriptions it makes, who releases each
// struct and when, the copy of a misaligned buffer, and the refusals. The
// streams come from the stand-in producer (tests/arrow_stand_in.c), whose
// counts show every release. A node --test file is its own process, so the
// counts are this file's.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import v8 from 'node:v8';
import vm from 'node:vm';

import type { ArrowAddon } from './src/arrow_import.mts';
import { NULLABLE, bitmap, bytes, bytesOf, fixed, streamOf, varlen, type StreamSpec } from './tests/arrow_specs.mts';

const here = import.meta.dirname;
const require = createRequire(import.meta.url);
const addon: ArrowAddon = require(path.join(here, 'komira_addon.node'));
const stand = require(path.join(here, 'arrow_stand_in.node'));
const foreign = require(path.join(here, 'foreign_external.node'));

v8.setFlagsFromString('--expose-gc');
const gc = vm.runInNewContext('gc');

// Collect garbage until `done()`, letting the finalizers of Node-API values
// run between collections (node runs them on the event loop); a bounded number
// of rounds, so no clock is read.
async function collect(done: () => boolean, rounds = 200): Promise<void> {
  for (let i = 0; i < rounds && !done(); i++) {
    gc();
    await new Promise((resolve) => setImmediate(resolve));
  }
}

interface Released {
  streams: number;
  schemas: number;
  arrays: number;
  bad: number;
}

// The stand-in's release counts of the stream of `capsule`.
function released(capsule: unknown): Released {
  const c = stand.counts(capsule);
  return { streams: c.streamReleases, schemas: c.schemaReleases, arrays: c.arrayReleases, bad: c.badReleases };
}

// Two batches of an int32 column and a utf8 column.
function twoBatches(): StreamSpec {
  const column = (n: number[], s: string[]) => {
    const [offsets, data] = varlen(s, false);
    return [
      fixed('n', 'i', n.length, Int32Array.from(n)),
      { schema: { format: 'u', name: 's', flags: NULLABLE }, array: { length: s.length, buffers: [null, offsets, data] } },
    ];
  };
  return streamOf([column([1, 2], ['a', 'bc']), column([3], ['d'])]);
}

test('the import releases the stream at once and holds the schema and the batches', async () => {
  const capsule = stand.stream(twoBatches());
  const result = await addon.importArrowStream(capsule);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 0, arrays: 0, bad: 0 });
  addon.arrowClose(result);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('arrowSchema describes every node of the schema', async () => {
  const result = await addon.importArrowStream(
    stand.stream({
      schema: {
        format: '+s',
        name: 'batch',
        metadata: [['origin', 'stand-in']],
        children: [
          { format: 'i', name: 'n', flags: NULLABLE, metadata: [['unit', 'm'], ['', 'empty key']] },
          { format: 's', flags: 1, dictionary: { format: 'u', name: 'values' } },
          { format: '+l', name: 'list', children: [{ format: 'g', name: 'item', flags: NULLABLE }] },
        ],
      },
      batches: [],
    }),
  );
  const leaf = (format: string, name: string | null, flags: number) => ({
    format,
    name,
    flags,
    metadata: null,
    children: [],
    dictionary: null,
  });
  assert.deepEqual(addon.arrowSchema(result), {
    format: '+s',
    name: 'batch',
    flags: 0,
    metadata: [['origin', 'stand-in']],
    children: [
      { ...leaf('i', 'n', NULLABLE), metadata: [['unit', 'm'], ['', 'empty key']] },
      { ...leaf('s', null, 1), dictionary: leaf('u', 'values', 0) },
      { ...leaf('+l', 'list', 0), children: [leaf('g', 'item', NULLABLE)] },
    ],
    dictionary: null,
  });
  // The schema is described again on request: the result still holds it.
  assert.equal(addon.arrowSchema(result).children.length, 3);
  addon.arrowClose(result);
});

test('arrowNextBatch describes each batch with buffers of the exact length, then null', async () => {
  const [offsets, data] = varlen(['ab', '', 'cde'], false);
  const spec = streamOf([
    [
      // Two slots skipped and three read: the bitmap covers five slots.
      {
        schema: { format: 'l', name: 'n', flags: NULLABLE },
        array: { length: 3, offset: 2, nullCount: 1, buffers: [bitmap([true, true, true, false, true]), BigInt64Array.of(0n, 0n, 1n, 2n, 3n)] },
      },
      { schema: { format: 'u', name: 's' }, array: { length: 3, buffers: [null, offsets, data] } },
      fixed('b', 'b', 9, bitmap([true, false, true, false, true, false, true, false, true])),
      {
        schema: { format: '+ud:0', name: 'u', children: [{ format: 'c', name: 'c' }] },
        array: { length: 3, buffers: [Int8Array.of(0, 0, 0), Int32Array.of(0, 1, 2)], children: [{ length: 3, buffers: [null, Int8Array.of(4, 5, 6)] }] },
      },
    ],
  ]);
  spec.batches[0].length = 3;
  const result = await addon.importArrowStream(stand.stream(spec));
  const batch = addon.arrowNextBatch(result);
  assert.ok(batch !== null);
  assert.deepEqual([batch.length, batch.nullCount, batch.offset, batch.buffers, batch.dictionary], [3, 0, 0, [null], null]);
  const [n, s, b, u] = batch.children;
  assert.deepEqual([n.length, n.nullCount, n.offset], [3, 1, 2]);
  assert.deepEqual(n.buffers.map(bytesOf), [[0b10111], bytes(BigInt64Array.of(0n, 0n, 1n, 2n, 3n))]);
  // A utf8 data buffer ends at the last offset: five bytes.
  assert.deepEqual(s.buffers.map(bytesOf), [[], bytes(Int32Array.of(0, 2, 2, 5)), bytes(new TextEncoder().encode('abcde'))]);
  assert.equal(s.buffers[0], null);
  assert.deepEqual(b.buffers.map(bytesOf), [[], [0b01010101, 0b1]]);
  // A union has no validity bitmap: its buffers are the type ids and the offsets.
  assert.deepEqual(u.buffers.map(bytesOf), [[0, 0, 0], bytes(Int32Array.of(0, 1, 2))]);
  assert.deepEqual(u.children[0].buffers.map(bytesOf), [[], [4, 5, 6]]);
  assert.equal(addon.arrowNextBatch(result), null);
  assert.equal(addon.arrowNextBatch(result), null);
  addon.arrowClose(result);
});

test('an array of no slots reads none of its buffers, which may be empty', async () => {
  // Non-NULL buffers of no bytes: nothing is read from them, not even an offset.
  const spec = streamOf([[{ schema: { format: 'u', name: 's' }, array: { length: 0, buffers: [null, new Int32Array(0), new Uint8Array(0)] } }]]);
  const result = await addon.importArrowStream(stand.stream(spec));
  const batch = addon.arrowNextBatch(result);
  assert.ok(batch !== null);
  assert.deepEqual(batch.children[0].buffers.map((b) => (b === null ? null : b.byteLength)), [null, 0, 0]);
  addon.arrowClose(result);
});

test('a batch is released exactly once, only after its buffers are collected', async () => {
  const capsule = stand.stream(twoBatches());
  let batches: unknown[] | null = [];
  await (async () => {
    const result = await addon.importArrowStream(capsule);
    for (let a = addon.arrowNextBatch(result); a !== null; a = addon.arrowNextBatch(result)) batches?.push(a);
    addon.arrowClose(result);
  })();
  // The batches were taken before the close: it releases only the schema.
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 0, bad: 0 });
  await collect(() => false, 20);
  assert.equal(released(capsule).arrays, 0, 'a batch was released while its buffers were alive');
  assert.equal(batches.length, 2);
  batches = null;
  await collect(() => released(capsule).arrays >= 2);
  // Further collections release nothing more.
  await collect(() => false, 20);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('a misaligned buffer is copied, and a batch whose buffers are all copies is released when it is read', async () => {
  const [offsets, data] = varlen(['xy', 'z'], false);
  const spec = streamOf([
    [
      { schema: { format: 'g', name: 'f' }, array: { length: 2, buffers: [null, Float64Array.of(1.5, -2)], misalign: true } },
      { schema: { format: 'u', name: 's' }, array: { length: 2, buffers: [null, offsets, data], misalign: true } },
    ],
  ]);
  const capsule = stand.stream(spec);
  const result = await addon.importArrowStream(capsule);
  const batch = addon.arrowNextBatch(result);
  assert.ok(batch !== null);
  // Nothing of the batch's memory is held, so it is released already.
  assert.deepEqual(released(capsule), { streams: 1, schemas: 0, arrays: 1, bad: 0 });
  const [f, s] = batch.children;
  assert.deepEqual(new Float64Array(f.buffers[1] as ArrayBuffer), Float64Array.of(1.5, -2));
  assert.deepEqual(s.buffers.map(bytesOf), [[], bytes(offsets), bytes(data)]);
  addon.arrowClose(result);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 1, bad: 0 });
});

test('a get_schema failure rejects with its status and get_last_error text', async () => {
  const capsule = stand.stream({ ...twoBatches(), schemaError: { status: 22, message: 'stand-in: no schema' } });
  await assert.rejects(
    addon.importArrowStream(capsule),
    (err: unknown) => {
      assert.ok(err instanceof Error);
      assert.deepEqual({ ...err, message: err.message }, {
        code: 'KOMIRA_ARROW_STREAM',
        status: 22,
        lastError: 'stand-in: no schema',
        message: 'get_schema failed (status 22): stand-in: no schema',
      });
      return true;
    },
  );
  // The stream's release frees what it never handed out.
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('a get_next failure rejects, after the batch it handed out before, the schema and the stream are released once', async () => {
  const capsule = stand.stream({ ...twoBatches(), nextError: { at: 1, status: 5, message: 'stand-in: batch 2 cannot be read' } });
  await assert.rejects(addon.importArrowStream(capsule), {
    code: 'KOMIRA_ARROW_STREAM',
    status: 5,
    lastError: 'stand-in: batch 2 cannot be read',
    message: 'get_next failed (status 5): stand-in: batch 2 cannot be read',
  });
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('a failure with no last error has the status alone', async () => {
  await assert.rejects(addon.importArrowStream(stand.stream({ ...twoBatches(), nextError: { at: 0, status: 5 } })), {
    code: 'KOMIRA_ARROW_STREAM',
    status: 5,
    lastError: '',
    message: 'get_next failed (status 5)',
  });
});

test('a released schema and a schema that is not a struct are refused', async () => {
  const releasedSchema = stand.stream({ ...twoBatches(), releasedSchema: true });
  await assert.rejects(addon.importArrowStream(releasedSchema), {
    code: 'KOMIRA_ARROW_INVALID',
    message: 'get_schema returned a released schema',
  });
  // The stream's release frees the schema it never handed out.
  assert.deepEqual(released(releasedSchema), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
  const notStruct = stand.stream({ schema: { format: 'i' }, batches: [] });
  await assert.rejects(addon.importArrowStream(notStruct), {
    code: 'KOMIRA_ARROW_INVALID',
    message: 'the stream\'s schema has format "i", not a struct ("+s")',
  });
  assert.deepEqual(released(notStruct), { streams: 1, schemas: 1, arrays: 0, bad: 0 });
});

test('importArrowStream refuses what is not a capsule, and a capsule imported before', async () => {
  const notCapsule = { name: 'TypeError', code: 'KOMIRA_ARG', message: 'importArrowStream takes an Arrow C stream capsule' };
  for (const v of [undefined, {}, 'stream', foreign.make()]) {
    assert.throws(() => addon.importArrowStream(v), notCapsule);
  }
  assert.throws(() => (addon.importArrowStream as () => unknown)(), notCapsule);
  const capsule = stand.stream(twoBatches());
  addon.arrowClose(await addon.importArrowStream(capsule));
  assert.throws(() => addon.importArrowStream(capsule), {
    name: 'TypeError',
    code: 'KOMIRA_ARG',
    message: 'the Arrow C stream was already imported or released',
  });
});

test('a closed result refuses its calls, and closing again does nothing', async () => {
  const capsule = stand.stream(twoBatches());
  const result = await addon.importArrowStream(capsule);
  assert.ok(addon.arrowNextBatch(result) !== null);
  addon.arrowClose(result);
  // The batch not read and the schema are released by the close.
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 1, bad: 0 });
  assert.equal(addon.arrowClose(result), undefined);
  const closed = { code: 'KOMIRA_ARROW_CLOSED', message: 'the Arrow result was closed' };
  assert.throws(() => addon.arrowSchema(result), closed);
  assert.throws(() => addon.arrowNextBatch(result), closed);
  const notResult = { name: 'TypeError', code: 'KOMIRA_ARG', message: 'the result must be a value importArrowStream resolved to' };
  for (const v of [{}, foreign.make(), stand.stream(twoBatches())]) {
    assert.throws(() => addon.arrowSchema(v), notResult);
    assert.throws(() => addon.arrowNextBatch(v), notResult);
    assert.throws(() => addon.arrowClose(v), notResult);
  }
  await collect(() => released(capsule).arrays >= 2);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('a result that is never closed is released by its finalizer', async () => {
  const capsule = stand.stream(twoBatches());
  await (async () => {
    await addon.importArrowStream(capsule);
  })();
  await collect(() => released(capsule).schemas >= 1);
  assert.deepEqual(released(capsule), { streams: 1, schemas: 1, arrays: 2, bad: 0 });
});

test('an array that does not match its format is refused, naming the column, and is released', async () => {
  const int = (array: object) => ({ schema: { format: 'i', name: 'n' }, array: { length: 1, ...array } });
  // A stream of one batch of `length` rows over `columns`.
  const batchOf = (length: number, columns: ReturnType<typeof int>[]) => {
    const spec = streamOf([columns]);
    spec.batches[0].length = length;
    return spec;
  };
  const cases: [StreamSpec, string][] = [
    [streamOf([[int({ buffers: [null] })]]), 'column "n": format "i" has 2 buffers, the array has 1'],
    [streamOf([[int({ buffers: [null, null] })]]), 'column "n": buffer 1 is NULL'],
    [batchOf(1, [int({ length: -1, buffers: [null, Int32Array.of(1)] })]), 'column "n": length -1, offset 0 and null count 0 are out of range'],
    [batchOf(-2, [int({ buffers: [null, Int32Array.of(1)] })]), 'the batch: length -2, offset 0 and null count 0 are out of range'],
    [
      batchOf(1, [int({ length: 2 ** 53 + 2, buffers: [null, Int32Array.of(1)] })]),
      'column "n": length 9007199254740994, offset 0 and null count 0 are out of range',
    ],
    [streamOf([[int({ nullCount: 2, buffers: [null, Int32Array.of(1)] })]]), 'column "n": length 1, offset 0 and null count 2 are out of range'],
    [
      streamOf([[{ schema: { format: 'u', name: 's' }, array: { length: 1, buffers: [null, Int32Array.of(0, -4), new Uint8Array(0)] } }]]),
      'column "s": the last offset is negative (-4)',
    ],
    [
      streamOf([
        [
          {
            schema: { format: '+s', name: 'st', children: [{ format: 'i', name: 'a' }, { format: 'i', name: 'b' }] },
            array: { length: 1, buffers: [null], children: [{ length: 1, buffers: [null, Int32Array.of(1)] }] },
          },
        ],
      ]),
      'column "st": the schema has 2 children, the array has 1',
    ],
    [
      streamOf([[{ schema: { format: 'i', name: 'd', dictionary: { format: 'u' } }, array: { length: 1, buffers: [null, Int32Array.of(0)] } }]]),
      'column "d": the array has no dictionary',
    ],
    [
      streamOf([[int({ buffers: [null, Int32Array.of(0)], dictionary: { length: 0, buffers: [null, null, null] } })]]),
      'column "n": the array has a dictionary the schema does not',
    ],
    [
      streamOf([[{ schema: { format: 'g', name: 'd', dictionary: { format: 'u' } }, array: { length: 1, buffers: [null, Float64Array.of(0)] } }]]),
      'column "d": dictionary index format "g" is not an integer',
    ],
    [
      streamOf([[{ schema: { format: 'w:4', name: 'fsb' }, array: { length: 1, buffers: [null, Int32Array.of(0)] } }]]),
      'column "fsb": format "w:4" is not supported',
    ],
    [
      streamOf([
        [
          {
            schema: { format: '+s', name: 'outer', children: [{ format: 'i', name: 'inner' }] },
            array: { length: 1, buffers: [null], children: [{ length: 1, buffers: [null] }] },
          },
        ],
      ]),
      'column "outer.inner": format "i" has 2 buffers, the array has 1',
    ],
  ];
  const capsules = cases.map(([spec]) => stand.stream(spec));
  for (const [i, [, message]] of cases.entries()) {
    const result = await addon.importArrowStream(capsules[i]);
    assert.throws(() => addon.arrowNextBatch(result), { code: 'KOMIRA_ARROW_INVALID', message });
    addon.arrowClose(result);
  }
  // A refused batch is released once the buffers made before the refusal are collected.
  await collect(() => capsules.every((c) => released(c).arrays >= 1));
  for (const c of capsules) assert.deepEqual(released(c), { streams: 1, schemas: 1, arrays: 1, bad: 0 });
});
