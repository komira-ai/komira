// A node --test file with a failing test: node_binding_test `binding_fails`
// must fail with node's exit status.
import assert from 'node:assert/strict';
import test from 'node:test';

test('passes', () => {
  assert.equal(1, 1);
});

test('the negative binding fixture fails its own assertion', () => {
  assert.equal(6 * 7, 41, 'the negative binding fixture fails its own assertion');
});
