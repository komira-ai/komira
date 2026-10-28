// The two-call protocol: the second call gets exactly the capacity the first
// call reported. The stand-in library writes the capacity it was given and the
// length it reported into the result, so an addon that passes more room than
// the length (an overrun the real library would not notice) is seen here. A
// node --test file is its own process, so the stand-in is this file's library.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';

const here = import.meta.dirname;
const addon = createRequire(import.meta.url)(path.join(here, 'komira_addon.node'));
addon.load(path.join(here, 'fake', 'libkomira_fake_capacity.so'));

const words = (result) => {
  const buf = typeof result === 'string' ? Buffer.from(result, 'latin1') : result;
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  return [view.getBigUint64(0, true), view.getBigUint64(8, true)];
};

test('parquetSchema passes the reported length as the capacity', () => {
  const buf = addon.parquetSchema(addon.newSession(), 'any.parquet');
  assert.equal(buf.length, 16);
  assert.deepEqual(words(buf), [16n, 16n]);
});

test('planRender passes the reported length as the capacity', () => {
  // planRender returns text; the stand-in's bytes are all below 0x80.
  const text = addon.planRender(addon.newSession(), new Uint8Array([1, 2, 3]));
  assert.equal(text.length, 16);
  assert.deepEqual(words(text), [16n, 16n]);
});
