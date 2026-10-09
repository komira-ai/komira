// The entry of the two-module bundle (BUCK, `two_module`): it imports a
// TypeScript sibling, so the bundle runs only if esbuild resolved the import
// and stripped the types. node_test stages the bundle alone, without
// greet.ts, so an unbundled import fails at load.
import assert from 'node:assert/strict';
import { fahrenheit, greet } from './greet.ts';

assert.equal(greet('bundle'), 'hello, bundle');
assert.deepEqual(Array.from(fahrenheit(Float64Array.of(0, 100, -40))), [32, 212, -40]);
console.log(greet('bundle'));
