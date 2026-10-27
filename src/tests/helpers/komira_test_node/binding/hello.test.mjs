// The smallest `node --test` file: node_binding_test (BUCK, `binding_hello`)
// runs it with the pinned node, and the target exists only if both tests ran
// and passed.
import assert from 'node:assert/strict';
import test from 'node:test';

test('arithmetic', () => {
  assert.equal(6 * 7, 42);
});

test('an async test is awaited', async () => {
  const v = await Promise.resolve('node --test');
  assert.equal(v, 'node --test');
});
