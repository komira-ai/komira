// No host Node.js and no worker library reaches a node_test action.
//
// Fails unless: node is the pinned version (argv[2]); process.execPath lies
// under the action's working directory, inside its buck-out/; the environment
// is exactly what node_test sets (no NODE_OPTIONS, NODE_PATH or PATH); every
// file the process maps lies under the working directory except glibc's own
// libraries (the host floor, tools/build/toolchains/README.md); and
// libstdc++.so.6 and libgcc_s.so.1 are mapped, from under the working
// directory. So a worker's /usr/bin/node or its libstdc++.so.6 is refused.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = process.cwd() + path.sep;

// glibc, which the host floor allows an action to take from the worker.
const GLIBC = new Set([
  'ld-linux-x86-64.so.2',
  'libc.so.6',
  'libdl.so.2',
  'libm.so.6',
  'libpthread.so.0',
  'librt.so.1',
]);

// The C++ runtime node links, which must come from the pinned packages.
const PINNED = ['libgcc_s.so.1', 'libstdc++.so.6'];

const want = process.argv[2];
assert.equal(process.versions.node, want, `node is ${process.versions.node}, the pin says ${want}`);

assert.ok(
  process.execPath.startsWith(ROOT) && process.execPath.includes('/buck-out/'),
  `process.execPath ${process.execPath} is outside the action's buck-out (${ROOT})`,
);

assert.deepEqual(
  Object.keys(process.env).sort(),
  ['HOME', 'LC_ALL', 'LD_LIBRARY_PATH', 'TMPDIR', 'TZ'],
  'the environment is not exactly what node_test sets',
);

const mapped = new Set();
for (const line of fs.readFileSync('/proc/self/maps', 'utf8').split('\n')) {
  // address perms offset dev inode [path]
  const fields = line.trim().split(/\s+/);
  if (fields.length >= 6 && fields[5].startsWith('/')) {
    mapped.add(fields.slice(5).join(' '));
  }
}
const outside = [...mapped].filter((p) => !p.startsWith(ROOT) && !GLIBC.has(path.basename(p))).sort();
assert.deepEqual(outside, [], 'files mapped from outside the action');
for (const lib of PINNED) {
  const from = [...mapped].filter((p) => path.basename(p) === lib);
  assert.equal(from.length, 1, `${lib} is mapped ${from.length} times: ${from}`);
  assert.ok(from[0].startsWith(ROOT), `${lib} is mapped from ${from[0]}`);
}
console.log(`node ${process.versions.node}: ${mapped.size} mapped files, all from the action or glibc`);
