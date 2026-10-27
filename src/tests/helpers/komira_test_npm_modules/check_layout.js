// Runs in the package directory with the laid-out node_modules linked in: what `npm ci --ignore-scripts`
// would have made of basic/package-lock.json, for linux x86_64.
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// A nested node_modules, a hoisted one and an alias each resolve to their own version.
assert.strictEqual(require('fx-a').bVersion, '2.0.0', 'fx-a sees its nested fx-b');
assert.strictEqual(require('fx-b').version, '1.0.0', 'the top-level fx-b');
assert.strictEqual(require('alias-b').version, '1.0.0', 'an alias installs under its own name');
assert.ok(require('@fx/scoped').scoped, 'a scoped package whose tarball has no package/ directory');
assert.strictEqual(require('fx-bundled-host').inner, 'inner', 'a bundled dependency comes from its parent tarball');

const nm = path.join(process.cwd(), 'node_modules');
// No install script ran, and the tarball's symlink entry was not extracted.
assert.ok(!fs.existsSync(path.join(nm, '@fx/scoped/install-ran')), 'an install script ran');
assert.ok(!fs.existsSync(path.join(nm, '@fx/scoped/link-out')), 'a tarball symlink was extracted');
// An optional package for another os is not installed.
assert.ok(!fs.existsSync(path.join(nm, 'fx-darwin')), 'fx-darwin (os: darwin) was installed');
// .bin: a relative link to the package's executable, which is executable; other files are not.
const link = path.join(nm, '.bin/fx-a');
assert.ok(fs.lstatSync(link).isSymbolicLink(), '.bin/fx-a is not a link');
assert.strictEqual(fs.readlinkSync(link), '../fx-a/bin/fx-a.js');
assert.ok(fs.statSync(link).mode & 0o111, 'the bin target is not executable');
assert.ok(!(fs.statSync(path.join(nm, 'fx-a/index.js')).mode & 0o111), 'a plain file is executable');
assert.ok(fs.existsSync(path.join(nm, '.bin/cdk')), '.bin/cdk');
// The assembly's own report names what it did not do.
const report = JSON.parse(fs.readFileSync(path.join(nm, '.komira-node-modules.json'), 'utf8'));
assert.deepStrictEqual(report.installScriptsNotRun, ['node_modules/@fx/scoped @fx/scoped@3.0.0']);
assert.ok(report.skipped.some((s) => s.startsWith('node_modules/fx-darwin ')), 'fx-darwin is reported skipped');
