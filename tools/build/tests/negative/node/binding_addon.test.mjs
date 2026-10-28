// The addon test of komira_test_node `binding_addon`, planted: the targets
// `binding_addon_missing` (the addon is not staged) and
// `binding_addon_wrong` (the addon returns 41) must fail.
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
  assert.equal(m.answer(), 42, 'answer() must return 42');
});
