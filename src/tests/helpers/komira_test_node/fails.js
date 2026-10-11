// A script that fails: node_test `fails` expects this assertion message on
// stderr, so it passes only if node_test reports a failing script as failed
// and shows its error.
'use strict';

const assert = require('node:assert/strict');

assert.equal(6 * 7, 41, 'node_test reports this failure');
