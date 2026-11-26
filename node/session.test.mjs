// The calls over the real libkomira: the version, the error path with the
// session's last error, the Parquet schema, the rendered plan and the
// lifetime of a session. The library is loaded by path, as a host does. The
// calls on a session return Promises (the session thread, thread.test.mjs);
// misuse of the addon throws before anything is queued.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import v8 from 'node:v8';
import vm from 'node:vm';

const here = import.meta.dirname;
const addon = createRequire(import.meta.url)(path.join(here, 'komira_addon.node'));
const foreign = createRequire(import.meta.url)(path.join(here, 'foreign_external.node'));
const PARQUET = path.join(here, 'two_columns.parquet');
addon.load(path.join(here, 'libkomira', 'libkomira.so'));

// The komira.plan.v1 WireSchema bytes komira_parquet_schema returns for
// two_columns.parquet (an int64 column "i64" and a string column "s").
const SCHEMA_HEX = '0a150a03693634100518052001280030003a00400450000a130a0173100d18002001280030003a0040045000';
// A serialized plan: one scan of "/data/orders.orc" (the plan wire's frozen
// scan example, the one src/so's gates render).
const SCAN_PLAN_HEX = '080412a903124c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500022d8020af90112f60108c0c2d2f703120a6b6f6d6972612e6f72631a066f7264657273221b0a0a6861735f666f6f74657210051a00200129000000000000000022250a047061746810011a102f646174612f6f72646572732e6f72632000290000000000000000221d0a0c7374726970655f636f756e7410021a0020072900000000000000002a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500030effdb6f50d38cef5b7f70f420a0803103f180120012801500258d285d8cc04600180010068007008780010011a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a0040045000200030004000480050015800';

function session() {
  return addon.newSession();
}

test('abiVersion is 1.9', () => {
  assert.equal(addon.abiVersion(), 1009);
});

test('a missing Parquet file rejects with an Error with status -3 and the last error text', async () => {
  const s = session();
  try {
    await assert.rejects(addon.registerParquet(s, 'gone', '/no/such/file.parquet'), (err) => {
      assert.ok(err instanceof Error);
      assert.equal(err.status, -3);
      assert.equal(err.code, 'KOMIRA_ERR_ENGINE');
      // A registration's refusal is at the bind step (KOMIRA_STEP_BIND), and
      // its named code is a string, empty when the reader's text names none.
      assert.equal(err.lastErrorStep, 2);
      assert.equal(typeof err.lastErrorCode, 'string');
      assert.equal(typeof err.lastError, 'string');
      assert.ok(err.lastError.length > 0, 'the engine gave no message');
      assert.ok(err.message.endsWith(`: ${err.lastError}`), `message ${err.message} lacks the last error`);
      assert.match(err.message, /komira_register_parquet failed \(status -3\)/);
      return true;
    });
  } finally {
    await addon.freeSession(s);
  }
});

test('a text file is refused as Parquet, and a good call afterwards works on the same session', async () => {
  const s = session();
  try {
    await assert.rejects(addon.parquetSchema(s, new URL(import.meta.url).pathname), { status: -3 });
    assert.equal(await addon.registerParquet(s, 'two', PARQUET), undefined);
  } finally {
    await addon.freeSession(s);
  }
});

test('parquetSchema resolves to the schema bytes as a Buffer', async () => {
  const s = session();
  try {
    const bytes = await addon.parquetSchema(s, PARQUET);
    assert.ok(Buffer.isBuffer(bytes));
    assert.equal(bytes.toString('hex'), SCHEMA_HEX);
    assert.ok(bytes.includes('i64') && bytes.includes('s'));
    assert.equal((await addon.parquetSchema(s, PARQUET)).toString('hex'), SCHEMA_HEX);
  } finally {
    await addon.freeSession(s);
  }
});

test('planRender resolves to the text of the plan, from a Buffer and from a Uint8Array view', async () => {
  const s = session();
  try {
    const plan = Buffer.from(SCAN_PLAN_HEX, 'hex');
    const text = await addon.planRender(s, plan);
    assert.equal(typeof text, 'string');
    assert.ok(text.startsWith('Scan(path="orders"'), text);
    assert.match(text, /komira\.orc\(orders/);
    assert.match(text, /path=\/data\/orders\.orc/);
    // A view into a larger buffer: the offset is honoured.
    const padded = new Uint8Array(plan.length + 7);
    padded.set(plan, 3);
    assert.equal(await addon.planRender(s, padded.subarray(3, 3 + plan.length)), text);
  } finally {
    await addon.freeSession(s);
  }
});

test('planRender of bytes that are not a plan rejects with status -3 and a last error', async () => {
  const s = session();
  try {
    for (const bad of [new Uint8Array([0xff, 0xff, 0xff]), new Uint8Array(0)]) {
      await assert.rejects(addon.planRender(s, bad), (err) => {
        assert.equal(err.status, -3);
        assert.ok(err.lastError.length > 0);
        return true;
      });
    }
  } finally {
    await addon.freeSession(s);
  }
});

test('newSession takes the engine options threads and memoryLimit, each 0 or left out for the engine default', async () => {
  const before = addon.sessionStats();
  for (const args of [[], [undefined, undefined], [0, 0], [2], [2, 1 << 20], [undefined, 1 << 20], [1, 1]]) {
    const s = addon.newSession(...args);
    await addon.registerParquet(s, 't', PARQUET);
    await addon.freeSession(s);
  }
  const after = addon.sessionStats();
  assert.deepEqual([after.created - before.created, after.freed - before.freed], [7, 7]);
});

test('newSession refuses an option that is not an integer from 0 to 2**53 - 1, and makes no context', () => {
  const before = addon.sessionStats();
  const cases = [
    [[-1], 'threads'], [[1.5], 'threads'], [['8'], 'threads'], [[Number.NaN], 'threads'], [[null], 'threads'],
    [[2 ** 53], 'threads'], [[Number.POSITIVE_INFINITY], 'threads'], [[8n], 'threads'],
    [[1, -1], 'memoryLimit'], [[1, 0.5], 'memoryLimit'], [[1, {}], 'memoryLimit'], [[undefined, 2 ** 53], 'memoryLimit'],
  ];
  for (const [args, what] of cases) {
    assert.throws(() => addon.newSession(...args), (err) => {
      assert.ok(err instanceof TypeError, String(err));
      assert.equal(err.code, 'KOMIRA_ARG');
      assert.equal(err.message, `${what} must be an integer from 0 to 2**53 - 1`);
      assert.equal(err.status, undefined);
      return true;
    }, String(args));
  }
  assert.equal(addon.sessionStats().created, before.created);
});

test('arguments of the wrong kind are TypeErrors with no status, thrown before anything is queued', async () => {
  const s = session();
  try {
    const refuse = (call) => assert.throws(call, (err) => {
      assert.ok(err instanceof TypeError, String(err));
      assert.equal(err.code, 'KOMIRA_ARG');
      assert.equal(err.status, undefined);
      return true;
    });
    refuse(() => addon.parquetSchema({}, PARQUET));
    refuse(() => addon.parquetSchema(s, 7));
    refuse(() => addon.parquetSchema(s, `${PARQUET}\0junk`));
    refuse(() => addon.registerParquet(s, 7, PARQUET));
    refuse(() => addon.planRender(s, 'a string'));
    refuse(() => addon.planRender(s, new Uint16Array(2)));
    refuse(() => addon.parquetSchema(s));
    refuse(() => addon.freeSession('not a session'));
    // An external value made by another addon is not a session either.
    refuse(() => addon.parquetSchema(foreign.make(), PARQUET));
    refuse(() => addon.freeSession(foreign.make()));
  } finally {
    await addon.freeSession(s);
  }
});

test('freeSession is idempotent, and a freed session is refused', async () => {
  const before = addon.sessionStats();
  const s = session();
  assert.equal(await addon.freeSession(s), undefined);
  assert.equal(await addon.freeSession(s), undefined);
  const after = addon.sessionStats();
  assert.equal(after.created - before.created, 1);
  assert.equal(after.freed - before.freed, 1, 'komira_ctx_free was not called exactly once');
  assert.throws(() => addon.parquetSchema(s, PARQUET), { code: 'KOMIRA_SESSION_FREED' });
  assert.throws(() => addon.planRender(s, new Uint8Array(1)), { code: 'KOMIRA_SESSION_FREED' });
});

test('two sessions are separate: freeing one leaves the other usable', async () => {
  const a = session();
  const b = session();
  await addon.freeSession(a);
  assert.equal(await addon.registerParquet(b, 'two', PARQUET), undefined);
  await addon.freeSession(b);
});

// Collect garbage, then let the finalizers of Node-API externals run (node
// runs them on the event loop, after the collection).
v8.setFlagsFromString('--expose-gc');
const gc = vm.runInNewContext('gc');
async function collect(done, rounds = 200) {
  for (let i = 0; i < rounds && !done(); i++) {
    gc();
    await new Promise((resolve) => setImmediate(resolve));
  }
}

test('a session that is never freed is freed once by its finalizer', async () => {
  const before = addon.sessionStats();
  (function makeAndDrop() {
    for (let i = 0; i < 5; i++) session();
  })();
  await collect(() => addon.sessionStats().freed - before.freed >= 5);
  const after = addon.sessionStats();
  assert.equal(after.created - before.created, 5);
  assert.equal(after.freed - before.freed, 5, 'the finalizers did not free the five sessions exactly once');
});

test('a session freed by freeSession is not freed again by its finalizer', async () => {
  const before = addon.sessionStats();
  (function makeFreeAndDrop() {
    for (let i = 0; i < 5; i++) addon.freeSession(session());
  })();
  assert.equal(addon.sessionStats().freed - before.freed, 5);
  // A fixed number of collections, so a finalizer that frees again has run.
  await collect(() => false, 50);
  const after = addon.sessionStats();
  assert.equal(after.created - before.created, 5);
  assert.equal(after.freed - before.freed, 5, 'a freed session was freed again by its finalizer');
});

test('a session whose calls ran on its thread and that is never freed is freed once by its finalizer', async () => {
  const before = addon.sessionStats();
  await (async function useAndDrop() {
    const s = session();
    assert.equal(await addon.registerParquet(s, 'two', PARQUET), undefined);
    assert.equal((await addon.parquetSchema(s, PARQUET)).toString('hex'), SCHEMA_HEX);
  })();
  await collect(() => addon.sessionStats().freed - before.freed >= 1);
  const after = addon.sessionStats();
  assert.equal(after.created - before.created, 1);
  assert.equal(after.freed - before.freed, 1, 'the finalizer did not free the session exactly once');
});
