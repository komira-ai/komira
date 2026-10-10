// apache-arrow, bundled with its dependencies (flatbuffers, tslib,
// json-with-bigint) by esbuild_bundle, writes an Arrow IPC stream and reads it
// back: a float64 column with a null and a utf8 column survive the round trip.
import assert from 'node:assert/strict';
import { Float64, Table, Utf8, makeVector, tableFromIPC, tableToIPC, vectorFromArray } from 'apache-arrow';

const temp = vectorFromArray([21.5, null, -40], new Float64());
const city = vectorFromArray(['oslo', 'lima', 'yakutsk'], new Utf8());
const table = new Table({ temp_c: temp, city });

const bytes = tableToIPC(table, 'stream');
// An IPC stream message starts with the continuation marker 0xFFFFFFFF.
assert.deepEqual(Array.from(bytes.subarray(0, 4)), [255, 255, 255, 255]);

const back = tableFromIPC(bytes);
assert.equal(back.numRows, 3);
assert.deepEqual(back.schema.fields.map((f) => `${f.name}:${f.type}`), ['temp_c:Float64', 'city:Utf8']);
const t = back.getChild('temp_c');
assert.equal(t.nullCount, 1);
assert.deepEqual([t.get(0), t.get(1), t.get(2)], [21.5, null, -40]);
assert.deepEqual(back.getChild('city').toArray(), ['oslo', 'lima', 'yakutsk']);
assert.equal(makeVector(Float64Array.of(1, 2)).length, 2);
console.log(`arrow ipc: ${bytes.length} bytes, ${back.numRows} rows`);
