// The session thread, over the stand-in library tests/fake_latch.c: every call
// on a session runs on that session's own native thread, one at a time and in
// the order the calls were made, and settles a Promise; two sessions run at
// once; freeSession waits for the calls made before it; a session is
// finalized only when no call is pending; a worker thread has sessions of its
// own. The stand-in journals each call with its context and thread, holds a
// call at a gate until the test opens it, and refuses a call made on the
// JavaScript thread, a second call at once on one context, and a call from a
// second thread. No test reads a clock: a test waits on a gate's entry, on a
// Promise, or on a worker's events.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import v8 from 'node:v8';
import vm from 'node:vm';
import { Worker } from 'node:worker_threads';

const here = import.meta.dirname;
const require = createRequire(import.meta.url);
const ADDON = path.join(here, 'komira_addon.node');
const LATCH = path.join(here, 'fake', 'libkomira_fake_latch.so');
const addon = require(ADDON);
const control = require(path.join(here, 'fake_control.node'));
addon.load(LATCH);
control.attach(LATCH);

// The stand-in's journal, one entry per line: `c<context> <what> t<thread>`.
const journal = () => control.journal().split('\n').filter(Boolean);
// The entries of context `id`, without the `c<id> ` prefix.
const of = (id) => journal().filter((l) => l.startsWith(`c${id} `)).map((l) => l.slice(`c${id} `.length));
// The thread of an entry: its last word.
const thread = (entry) => entry.split(' ').at(-1);

// A new session, the number of its context, and the JavaScript thread that
// made it.
function open() {
  const s = addon.newSession();
  const [, id, t] = /^c(\d+) new (t\d+)$/.exec(journal().filter((l) => / new t\d+$/.test(l)).at(-1));
  return { s, id: Number(id), js: t };
}

// Records the order in which Promises settle.
function settleOrder() {
  const order = [];
  const track = (label, p) => {
    assert.ok(p instanceof Promise, `${label} did not return a Promise`);
    return p.then(
      (v) => { order.push(label); return v; },
      (e) => { order.push(label); throw e; },
    );
  };
  return { order, track };
}

// The command that holds a call at gate `k`. Every gate a test uses is opened
// after it, so a test that fails early leaves no call held for the ones after.
const used = new Set();
function gate(k) {
  used.add(k);
  return `gate:${k}`;
}

test.afterEach(() => {
  for (const k of used) control.open(k);
  used.clear();
  assert.deepEqual(journal().filter((l) => l.endsWith(' refused')), [],
    'the stand-in refused a call: on the JavaScript thread, two at once on one context, or from a second thread');
});

test('calls on one session run one at a time in call order on one thread off the JavaScript thread, and settle in that order', async () => {
  const { s, id, js } = open();
  const { order, track } = settleOrder();
  const a = track('a', addon.registerParquet(s, gate(1), 'any.parquet'));
  const b = track('b', addon.parquetSchema(s, 'b-schema'));
  const c = track('c', addon.registerParquet(s, 'fail:c failed', 'any.parquet'));
  const d = track('d', addon.planRender(s, Buffer.from('d-plan')));
  control.waitEntered(1);
  // The first call is held in the library: the three after it wait for it.
  const held = of(id);
  assert.equal(held.length, 2, held.join(' | '));
  assert.equal(held[0], `new ${js}`);
  const worker = thread(held[1]);
  assert.equal(held[1], `register gate:1 ${worker}`);
  assert.notEqual(worker, js, 'the call ran on the JavaScript thread');
  control.open(1);
  assert.equal(await a, undefined);
  const schema = await b;
  assert.ok(Buffer.isBuffer(schema));
  assert.equal(schema.toString(), 'b-schema');
  await assert.rejects(c, (err) => {
    assert.ok(err instanceof Error);
    assert.equal(err.status, -3);
    assert.equal(err.code, 'KOMIRA_ERR_ENGINE');
    assert.equal(err.lastError, 'c failed');
    assert.equal(err.message, 'komira_register_parquet failed (status -3): c failed');
    return true;
  });
  assert.equal(await d, 'plan:d-plan');
  assert.deepEqual(order, ['a', 'b', 'c', 'd']);
  assert.equal(await addon.freeSession(s), undefined);
  assert.deepEqual(of(id), [
    `new ${js}`,
    `register gate:1 ${worker}`,
    `schema b-schema ${worker}`,
    `register fail:c failed ${worker}`,
    `render d-plan ${worker}`,
    `free ${worker}`,
  ]);
});

test('a call made after a failed call on the same session runs and succeeds', async () => {
  const { s, id } = open();
  await assert.rejects(addon.parquetSchema(s, 'fail:no such file'), { status: -3, lastError: 'no such file' });
  assert.equal((await addon.parquetSchema(s, 'after')).toString(), 'after');
  await addon.freeSession(s);
  assert.deepEqual(of(id).map((e) => e.split(' ').slice(0, -1).join(' ')),
    ['new', 'schema fail:no such file', 'schema after', 'free']);
});

test('two sessions run at once: a call on one settles while a call on the other is held', async () => {
  const one = open();
  const two = open();
  let oneSettled = false;
  const held = addon.registerParquet(one.s, gate(2), 'any.parquet').then(() => { oneSettled = true; });
  control.waitEntered(2);
  assert.equal(await addon.registerParquet(two.s, 'alone', 'any.parquet'), undefined);
  assert.equal(oneSettled, false, 'the held call settled before its gate opened');
  const t1 = thread(of(one.id)[1]);
  const t2 = thread(of(two.id)[1]);
  assert.notEqual(t1, t2, 'the two sessions share a thread');
  assert.notEqual(t1, one.js);
  assert.notEqual(t2, two.js);
  control.open(2);
  await held;
  assert.equal(oneSettled, true);
  await Promise.all([addon.freeSession(one.s), addon.freeSession(two.s)]);
});

test('freeSession while a call is held waits for it and for the calls queued before it, refuses later calls, and frees once', async () => {
  const { s, id, js } = open();
  const before = addon.sessionStats();
  const { order, track } = settleOrder();
  const held = track('held', addon.registerParquet(s, gate(3), 'any.parquet'));
  const queued = track('queued', addon.parquetSchema(s, 'queued'));
  control.waitEntered(3);
  const free1 = track('free1', addon.freeSession(s));
  // Refused at once, before anything is queued: the session takes no call.
  for (const call of [
    () => addon.registerParquet(s, 'late', 'any.parquet'),
    () => addon.parquetSchema(s, 'late'),
    () => addon.planRender(s, Buffer.from('late')),
  ]) {
    assert.throws(call, (err) => {
      assert.equal(err.code, 'KOMIRA_SESSION_FREED');
      assert.equal(err.status, undefined);
      return true;
    });
  }
  const free2 = track('free2', addon.freeSession(s));
  assert.equal(addon.sessionStats().freed, before.freed, 'the context was freed under a running call');
  assert.ok(!of(id).some((e) => e.startsWith('free ')));
  control.open(3);
  assert.equal(await held, undefined);
  assert.equal((await queued).toString(), 'queued');
  assert.equal(await free1, undefined);
  assert.equal(await free2, undefined);
  assert.deepEqual(order, ['held', 'queued', 'free1', 'free2']);
  assert.equal(addon.sessionStats().freed - before.freed, 1);
  assert.equal(await addon.freeSession(s), undefined, 'a third freeSession, after the free, is a no-op');
  assert.equal(addon.sessionStats().freed - before.freed, 1, 'komira_ctx_free was not called exactly once');
  const entries = of(id);
  const worker = thread(entries[1]);
  assert.deepEqual(entries, [`new ${js}`, `register gate:3 ${worker}`, `schema queued ${worker}`, `free ${worker}`]);
});

test('freeSession of a session that made no call frees it before it returns', async () => {
  const { s, id, js } = open();
  const p = addon.freeSession(s);
  assert.ok(p instanceof Promise);
  assert.deepEqual(of(id), [`new ${js}`, `free ${js}`]);
  assert.equal(await p, undefined);
  assert.throws(() => addon.parquetSchema(s, 'x'), { code: 'KOMIRA_SESSION_FREED' });
});

test('a call copies its plan bytes when it is made: changing the array while the call is queued changes nothing', async () => {
  const { s } = open();
  const held = addon.registerParquet(s, gate(4), 'any.parquet');
  const plan = Buffer.from('original');
  const rendered = addon.planRender(s, plan);
  const empty = addon.planRender(s, new Uint8Array(0));
  plan.fill(0x7a);
  control.waitEntered(4);
  control.open(4);
  await held;
  assert.equal(await rendered, 'plan:original');
  assert.equal(await empty, 'plan:', 'an empty plan is passed as empty bytes');
  await addon.freeSession(s);
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

test('a session dropped while its call is held is not finalized until the call settles, then is freed once', async () => {
  let id;
  let js;
  const pending = (() => {
    const made = open();
    id = made.id;
    js = made.js;
    return addon.registerParquet(made.s, gate(5), 'any.parquet');
  })();
  control.waitEntered(5);
  // A fixed number of collections: a finalizer that runs under the pending
  // call has run by then.
  await collect(() => false, 50);
  assert.ok(!of(id).some((e) => e.startsWith('free ')), 'the session was finalized while its call was pending');
  control.open(5);
  assert.equal(await pending, undefined);
  await collect(() => of(id).some((e) => e.startsWith('free ')));
  const entries = of(id);
  assert.equal(entries.filter((e) => e.startsWith('free ')).length, 1, entries.join(' | '));
  // The finalizer stops and joins the session thread, then frees the context
  // on the JavaScript thread.
  assert.equal(entries.at(-1), `free ${js}`);
});

// A worker thread that loads the addon and the stand-in (the process's one
// library: the same path), queues a held call, says so, and posts the result
// of a call made after it. It never frees its session.
const WORKER = `
const { parentPort, workerData } = require('node:worker_threads');
const addon = require(workerData.addon);
addon.load(workerData.lib);
const s = addon.newSession();
addon.registerParquet(s, workerData.cmd, 'any.parquet')
  .then(() => addon.parquetSchema(s, 'from the worker'))
  .then((bytes) => parentPort.postMessage(bytes.toString()));
parentPort.postMessage('queued');
`;

function worker(cmd) {
  const w = new Worker(WORKER, { eval: true, workerData: { addon: ADDON, lib: LATCH, cmd } });
  const messages = [];
  w.on('message', (m) => messages.push(m));
  return { w, messages };
}

// The context of the call with `cmd`, from the journal.
const contextOf = (cmd) => Number(/^c(\d+) /.exec(journal().find((l) => l.includes(` ${cmd} `)))[1]);

test('a worker thread runs its session on a thread of its own, its pending call keeps it alive until it settles, and an idle session lets it exit and is freed', async () => {
  const before = addon.sessionStats();
  const { w, messages } = worker(gate(6));
  const exited = once(w, 'exit');
  await once(w, 'message');
  control.waitEntered(6);
  control.open(6);
  const [code] = await exited;
  assert.equal(code, 0);
  assert.deepEqual(messages, ['queued', 'from the worker']);
  const entries = of(contextOf('gate:6'));
  const maker = thread(entries[0]);
  const runner = thread(entries[1]);
  assert.notEqual(runner, maker);
  assert.deepEqual(entries, [
    `new ${maker}`,
    `register gate:6 ${runner}`,
    `schema from the worker ${runner}`,
    `free ${maker}`,
  ]);
  const after = addon.sessionStats();
  assert.equal(after.created - before.created, 1);
  assert.equal(after.freed - before.freed, 1, 'the worker\'s session was not freed once when the worker exited');
});

test('a worker terminated while its call is held waits for the call, frees the context once, and exits', async () => {
  const before = addon.sessionStats();
  const { w, messages } = worker(gate(7));
  await once(w, 'message');
  control.waitEntered(7);
  const stopped = w.terminate();
  control.open(7);
  assert.equal(await stopped, 1);
  assert.equal(messages[0], 'queued');
  const entries = of(contextOf('gate:7'));
  assert.equal(entries.filter((e) => e.startsWith('free ')).length, 1, entries.join(' | '));
  assert.equal(addon.sessionStats().freed - before.freed, 1);
});
