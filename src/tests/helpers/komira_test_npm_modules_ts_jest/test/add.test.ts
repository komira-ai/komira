import * as fs from 'node:fs';
import { add } from '../src/add';

test('add adds', () => {
  expect(add(2, 3)).toBe(5);
});

// jest ran from the package's copy in the action's scratch directory, with its cache there.
test('the working directory holds node_modules and a cache directory is writable', () => {
  expect(fs.existsSync('node_modules/.bin/jest')).toBe(true);
  fs.mkdirSync('.jest-cache', { recursive: true });
});
