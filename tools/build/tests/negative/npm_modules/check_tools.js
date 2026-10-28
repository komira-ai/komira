// PATH holds node's directory and the links of `tools`, nothing else: bzip2 (busybox's applet) runs and
// round-trips, ls (which the host has) does not exist.
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');

const data = Buffer.from('tools on PATH');
const packed = execFileSync('bzip2', ['-c'], { input: data });
assert.ok(packed.subarray(0, 3).toString() === 'BZh', 'bzip2 -c did not write a bzip2 stream');
assert.strictEqual(execFileSync('bzip2', ['-dc'], { input: packed }).toString(), 'tools on PATH');
assert.throws(() => execFileSync('ls', ['/']), { code: 'ENOENT' });
