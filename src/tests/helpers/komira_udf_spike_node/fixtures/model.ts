// User code that holds a model, as a loaded model would be: 16 MiB in module
// scope, so each context that loads this bundle holds its own copy.
import type { Float64, Vector } from "apache-arrow";

const MODEL = new Float64Array(2 * 1024 * 1024).fill(0.5);
export function score(c: Vector<Float64>): Float64Array {
  const x = c.toArray();
  const out = new Float64Array(x.length);
  for (let i = 0; i < x.length; i++) out[i] = Math.tanh(x[i] * MODEL[i & 1023]);
  return out;
}
