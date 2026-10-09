// The komira-test/node worker: `node worker.mjs --code-dir <dir>
// [--corrupt-output]`, started by
// the engine's worker proxy (proxy/node_launcher.c) with its control channel
// on fd 3 and its cancel word on fd 4. It serves one context: the engine
// starts one worker per engine thread, so one isolate runs one thread's UDF
// calls and no lock is shared across engine threads. --corrupt-output makes
// call_batch's outputs break the IPC layout (arrow_io.mjs, corruptParts), for
// the test of the engine's validation of what a worker sends.

import { Runtime } from './runtime.mjs';
import { nextRequest } from './wire.mjs';

function codeDir(argv) {
  const i = argv.indexOf('--code-dir');
  if (i < 0 || i + 1 >= argv.length || argv[i + 1] === '') {
    process.stderr.write('komira udf worker: usage: worker.mjs --code-dir <dir>\n');
    process.exit(64);
  }
  return argv[i + 1];
}

const argv = process.argv.slice(2);
const rt = new Runtime(codeDir(argv), argv.includes('--corrupt-output'));
for (;;) {
  const t0 = process.hrtime.bigint();
  const req = nextRequest();
  rt.stats.idle_ns += process.hrtime.bigint() - t0;
  rt.handle(req);
}
