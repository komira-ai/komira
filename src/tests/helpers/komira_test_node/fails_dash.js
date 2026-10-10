// A script that fails with an error that starts with "--": node_test
// `fails_dash` expects that text on stderr, so it passes only if node_test
// hands expect_error to its matcher as text, not as an option.
'use strict';

console.error('--flag-like text node_test must match');
process.exitCode = 1;
