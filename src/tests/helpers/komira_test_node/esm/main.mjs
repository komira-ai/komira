// The entry of the esm bundle (BUCK, `esm`): it runs only as an ES module.
// esbuild refuses a top-level `await` in the cjs format, so a bundle written
// as cjs fails to build; and `import.meta.url` is a file: URL only in an ES
// module node loaded (esbuild empties `import.meta` in cjs).
import assert from 'node:assert/strict';
import { greet } from '../two_module/greet.ts';

const said = await Promise.resolve(greet('esm'));
assert.equal(said, 'hello, esm');
assert.ok(import.meta.url.startsWith('file:'), `import.meta.url is ${import.meta.url}`);
console.log(said);
