// Calls `pick` one way and `unused`: every line runs, and the `false` arm of
// `pick` does not. node_binding_test `binding_under_covered_branches` must
// fail on its branch coverage.
import assert from 'node:assert/strict';
import test from 'node:test';
import { pick, unused } from './binding_cover_lib.mjs';

test('pick takes one arm, and unused runs', () => {
  assert.equal(pick(true), 'one');
  assert.equal(unused(), 42);
});
