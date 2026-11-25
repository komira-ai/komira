// Calls `pick` both ways and never `unused`: every branch of what runs is
// taken, and the lines of `unused` are not run. node_binding_test
// `binding_under_covered_lines` must fail on its line coverage.
import assert from 'node:assert/strict';
import test from 'node:test';
import { pick } from './binding_cover_lib.mjs';

test('pick takes both arms', () => {
  assert.equal(pick(true), 'one');
  assert.equal(pick(false), 'two');
});
