// The benchmark's user module: one conversion written two ways, as a user
// writes it. The plan's verb carries the return type (float64), so the code
// declares only TypeScript types; esbuild bundles this module alone
// (BUCK, :fahrenheit_bundle).

import type { Float64, Vector } from 'apache-arrow';

// Per row: the runtime calls it once per row, inside the worker.
export function fahrenheitRow(c: number): number {
  return c * 1.8 + 32;
}

// Per batch, over the column as an Arrow Vector.
export function fahrenheitBatch(c: Vector<Float64>): Float64Array {
  const v = c.toArray() as Float64Array;
  const out = new Float64Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i] * 1.8 + 32;
  return out;
}

// The crossing alone: the column back unchanged.
export function same(c: Vector<Float64>): Vector<Float64> {
  return c;
}
