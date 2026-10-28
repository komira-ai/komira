// A node --test file whose only test is skipped: node exits 0, and
// node_binding_test `binding_skipped` must still fail.
import test from 'node:test';

test('skipped on purpose', { skip: true }, () => {});
