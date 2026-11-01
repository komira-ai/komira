// load(): the addon opens libkomira from the path it is given, checks the ABI
// major version, and says why when it cannot. A node --test file is its own
// process, and the addon holds one library per process, so the refusals come
// first (each leaves the addon unloaded) and the good load last.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';

const here = import.meta.dirname;
const addon = createRequire(import.meta.url)(path.join(here, 'komira_addon.node'));
const REAL = path.join(here, 'libkomira', 'libkomira.so');
const fake = (name) => path.join(here, 'fake', name);

test('the addon exposes exactly its calls', () => {
  assert.deepEqual(Object.keys(addon).sort(), [
    'abiVersion', 'freeSession', 'load', 'newSession', 'parquetSchema',
    'planRender', 'registerParquet', 'sessionStats',
  ]);
});

test('before load, every call that needs the library says it is not loaded', () => {
  for (const call of [() => addon.abiVersion(), () => addon.newSession()]) {
    assert.throws(call, { code: 'KOMIRA_NOT_LOADED', message: /not loaded/ });
  }
});

test('load refuses a path that is not a string, and one with a NUL byte', () => {
  assert.throws(() => addon.load(42), { name: 'TypeError', code: 'KOMIRA_ARG' });
  assert.throws(() => addon.load(`${REAL}\0.so`), { name: 'TypeError', code: 'KOMIRA_ARG', message: /NUL/ });
  assert.throws(() => addon.load(), { name: 'TypeError', code: 'KOMIRA_ARG' });
});

test('a path with no library is a load failure that carries the loader message', () => {
  assert.throws(() => addon.load(path.join(here, 'no_such_dir', 'libkomira.so')), {
    code: 'KOMIRA_LOAD_FAILED',
    message: /cannot load libkomira: .*no_such_dir/,
  });
});

test('a library of ABI major 2 is refused with its version', () => {
  assert.throws(() => addon.load(fake('libkomira_fake_v2.so')), {
    code: 'KOMIRA_ABI_MISMATCH',
    message: /ABI version 2\.0; this addon needs major 1/,
  });
});

test('a library of ABI major 0 is refused with its version', () => {
  assert.throws(() => addon.load(fake('libkomira_fake_v0.so')), {
    code: 'KOMIRA_ABI_MISMATCH',
    message: /ABI version 0\.999; this addon needs major 1/,
  });
});

test('a library without komira_plan_render names the missing symbol', () => {
  assert.throws(() => addon.load(fake('libkomira_fake_no_render.so')), {
    code: 'KOMIRA_MISSING_SYMBOL',
    message: /no symbol komira_plan_render/,
  });
});

test('after the refusals the addon is still unloaded', () => {
  assert.throws(() => addon.abiVersion(), { code: 'KOMIRA_NOT_LOADED' });
});

test('the real library loads, reports ABI 1.1, and loading it again is a no-op', () => {
  assert.equal(addon.load(REAL), undefined);
  assert.equal(addon.abiVersion(), 1001);
  assert.equal(addon.load(REAL), undefined);
  assert.equal(addon.abiVersion(), 1001);
});

test('another path is refused once a library is loaded', () => {
  assert.throws(() => addon.load(fake('libkomira_fake_v2.so')), { code: 'KOMIRA_LOADED' });
  assert.equal(addon.abiVersion(), 1001);
});
