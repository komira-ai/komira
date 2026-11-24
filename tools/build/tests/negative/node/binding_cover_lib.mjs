// The covered source of the binding coverage fixtures: `pick` is one line
// with two arms, and `unused` is three lines no test calls.
export const pick = (a) => (a ? 'one' : 'two');

export function unused() {
  const x = 2;
  return x * 21;
}
