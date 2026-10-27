// The addon built by node_addon (BUCK, `answer`) is loaded with require() and
// called: a binding test in node's own runner. The target
// `binding_addon` stages the addon next to this file as `answer.node`.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';

const addon = path.join(import.meta.dirname, 'answer.node');
const require = createRequire(import.meta.url);

test('the addon was built and staged', () => {
  assert.ok(existsSync(addon), 'answer.node was not built or staged');
});

test('answer() returns 42', () => {
  const m = require(addon);
  assert.equal(typeof m.answer, 'function');
  assert.equal(m.answer(), 42, 'answer() must return 42');
});
