// tsc_build's target is the directory the compiler wrote, and it compiled the TypeScript.
const assert = require('node:assert');
assert.strictEqual(require('./dist/add.js').add(2, 3), 5);
