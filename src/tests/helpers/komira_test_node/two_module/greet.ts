// The second module of the two-module bundle, in TypeScript.
export function greet(who: string): string {
  return `hello, ${who}`;
}

export function fahrenheit(c: Float64Array): Float64Array {
  const out = new Float64Array(c.length);
  for (let i = 0; i < c.length; i++) out[i] = c[i] * 1.8 + 32;
  return out;
}
