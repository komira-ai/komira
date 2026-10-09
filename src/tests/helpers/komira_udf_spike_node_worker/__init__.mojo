"""komira_udf_spike_node_worker: a Node.js UDF runtime on the worker
transport of docs/design/udf_runtime_interface.md, and the engine loop that
measures it on N engine threads. Test-only spike code.

- proxy/: the engine side of the worker transport, in C: a runtime table
  whose entries send one request per call to a worker process over a Unix
  socket pair, with Arrow IPC payloads (node_worker.so, launcher `node`).
- worker/: the worker, in JavaScript: the komira-test/node runtime, which
  runs module-level functions of an esbuild bundle with apache-arrow from
  the node_modules beside it.
- udf/: the user modules the tests and the bench load, in TypeScript.
- engine: Workload and run(), the engine's call loop over N engine threads
  (native/engine_loop.c), with no pointer in its API.
- node_cases: the shared conformance cases of komira_udf_spike_abi that user
  code can express, with their entries in this runtime's `<bundle>#<export>`
  form.
"""
