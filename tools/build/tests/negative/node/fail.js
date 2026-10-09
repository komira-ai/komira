// A script that fails: node_test `script_fails` (no expect_error) must fail
// with this assertion on stderr, and `error_not_on_stderr` must fail because
// its expect_error is text this script never prints.
'use strict';

const assert = require('node:assert/strict');

assert.equal(6 * 7, 41, 'the negative fixture fails its own assertion');
