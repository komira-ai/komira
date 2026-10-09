// A script that fails and prints node_test `error_on_stdout`'s expect_error
// on stdout only: the target must fail, because that text is not on stderr.
'use strict';

console.log('printed on stdout only');
process.exitCode = 1;
