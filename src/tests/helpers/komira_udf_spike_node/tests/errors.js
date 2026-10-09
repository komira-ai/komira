// What the runtime refuses, and how it says so. Argument: the build.
//
// validate (no user code runs, the bundle's text is read): an entry that is
// not `<relative bundle>.js#<export>` (no '#', a '..', an absolute path), a
// bundle that is not in the code directory, an export the bundle does not
// have, a type this runtime does not map (float32), a shape it does not
// declare (grouped frames) or two shape bits, a spec that lists code objects
// (their digests cannot be checked here), and a ROW whose read set names a
// field twice, each with its status.
//
// Calls: a function returning what the declared type does not allow is
// ERR_RETURN_TYPE and names the type (0.5 for int64, a string for float64, a
// Float64Array for an int64 column), a thrown string is ERR_RAISED with the
// string as its message, and an export of the wrong kind for the shape (an
// aggregate object under SCALAR, a function under AGG_MERGEABLE) is ERR_LOAD
// at open_instance.
//
// An int32 result outside 32 bits and an int64 result outside 64 bits are
// ERR_RETURN_TYPE at either end (both bounds are inclusive); the largest and
// smallest of each pass.
//
// Defects caught: a validator that lets a bad entry through to a mid-run
// failure; a lossy cast accepted (0.5 stored as 0); a thrown non-Error lost
// or crashing the adapter; a mismatch of export and shape found only at the
// first row.
//
// Mutant planted (adapter.js): storeFor('l') accepting a non-integer number
// by truncating it: red (float_into_int returns OK); storeFor('i') without its
// range check: red (3e9 stored as a wrapped int32, status OK); a bound of
// storeFor('i') or storeFor('l') made exclusive: red on the edges.
'use strict';

const assert = require('node:assert/strict');
const h = require('./helpers.js');

const variant = process.argv[2];

h.watchdog(`errors ${variant}`);

(async () => {
  const { file } = h.loadRuntime(variant);
  const engine = h.engineHost();
  const handle = engine.engineOpen(file);
  assert.equal(engine.engineInfo(handle).status, 0);
  const { SHAPE, STATUS, R } = h;
  const base = (entry, extra = {}) => ({ entry, shape: SHAPE.SCALAR, nArgs: 1, argFmt: 'l', resultFmt: 'l', ...extra });

  // ---- validate ----
  const refuses = (what, o, status, text) => {
    const r = engine.validateSpec(handle, o);
    assert.equal(r.status, status, `${what}: status ${r.status} (${r.message}), expected ${status}`);
    assert.ok(r.message.includes(text), `${what}: message '${r.message}' lacks '${text}'`);
  };
  assert.equal(engine.validateSpec(handle, base('fixtures.js#double')).status, 0, 'a good entry validates');
  refuses('no #', base('fixtures.js'), STATUS.DESCRIPTOR, 'entry');
  refuses('..', base('../fixtures.js#double'), STATUS.DESCRIPTOR, 'entry');
  refuses('absolute', base('/fixtures.js#double'), STATUS.DESCRIPTOR, 'entry');
  refuses('not .js', base('fixtures.ts#double'), STATUS.DESCRIPTOR, 'entry');
  refuses('no bundle', base('nope.js#double'), STATUS.DESCRIPTOR, 'bundle');
  refuses('no export', base('fixtures.js#nothing_of_this_name'), STATUS.DESCRIPTOR, 'exports nothing');
  refuses('float32', base('fixtures.js#double', { argFmt: 'f' }), STATUS.UNSUPPORTED, 'argument type');
  refuses('grouped', base('fixtures.js#double', { shape: SHAPE.FRAME_GROUPED }), STATUS.UNSUPPORTED, 'shape');
  refuses('two bits', base('fixtures.js#double', { shape: SHAPE.SCALAR | SHAPE.COLUMN }), STATUS.UNSUPPORTED, 'shape');
  refuses('code objects', base('fixtures.js#double', { nCode: 1 }), STATUS.UNSUPPORTED, 'code objects');
  refuses('duplicate field', base('fixtures.js#pick', { shape: SHAPE.ROW, nArgs: 2, argNames: 'a,a' }), STATUS.DESCRIPTOR, 'twice');

  // ---- calls ----
  const run = async (o) => h.summary(await engine.run(handle, { threads: 1, warmupMin: 1, warmupCap: 1, batches: 1, rows: 16, ...o }));
  const fails = async (what, o, status, text) => {
    const r = await run(o);
    assert.equal(r.run[R.STATUS], status, `${what}: status ${r.run[R.STATUS]} (${r.message})`);
    assert.ok(r.message.includes(text), `${what}: '${r.message}' lacks '${text}'`);
  };
  await fails('0.5 for int64', base('fixtures.js#float_into_int'), STATUS.RETURN_TYPE, 'not an integer');
  const i32 = { argFmt: 'i', resultFmt: 'i' };
  await fails('3e9 for int32', base('fixtures.js#int32_too_high', i32), STATUS.RETURN_TYPE, 'int32');
  await fails('-3e9 for int32', base('fixtures.js#int32_too_low', i32), STATUS.RETURN_TYPE, 'int32');
  await fails('2^63 for int64', base('fixtures.js#int64_too_high'), STATUS.RETURN_TYPE, 'int64');
  await fails('-2^63-1 for int64', base('fixtures.js#int64_too_low'), STATUS.RETURN_TYPE, 'int64');
  {
    // the edges themselves are accepted: both bounds are inclusive
    const r = await run(base('fixtures.js#int32_edges', i32));
    assert.equal(r.run[R.STATUS], 0, `int32 edges: ${r.message}`);
    const r64 = await run(base('fixtures.js#int64_edges'));
    assert.equal(r64.run[R.STATUS], 0, `int64 edges: ${r64.message}`);
  }
  await fails('a string for float64', base('fixtures.js#returns_string', { argFmt: 'g', resultFmt: 'g' }), STATUS.RETURN_TYPE, 'string');
  await fails('a Float64Array for int64', base('fixtures.js#wrong_array', { shape: SHAPE.COLUMN }), STATUS.RETURN_TYPE, 'Float64Array');
  await fails('a thrown string', base('fixtures.js#throws_string'), STATUS.RAISED, 'a thrown string');
  await fails('an aggregate under SCALAR', base('fixtures.js#sum'), STATUS.LOAD, 'is not a function');
  await fails('a function under AGG_MERGEABLE', base('fixtures.js#double', { shape: SHAPE.AGG_MERGEABLE }), STATUS.LOAD, 'aggregate');

  engine.engineClose(handle);
  console.log(`errors ${variant}: ok`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
