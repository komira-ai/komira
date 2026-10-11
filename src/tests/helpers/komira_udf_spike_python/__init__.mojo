"""komira_udf_spike_python: a Python UDF runtime that embeds CPython behind
the C ABI of docs/design/udf_runtime_interface.md, and the engine loop that
measures it on N engine threads. Test-only spike code.

- pyrt/: the runtime, in C (python_runtime.c, python_call.c, pyapi.c), its
  Python adapter (komira_udf_pyrt.py) and the user functions the tests load.
  Built twice: one sub-interpreter with its own GIL per context, and the
  shared-interpreter baseline (refrt/).
- engine: Engine and Workload, the engine's call loop over N engine threads
  (native/engine_loop.c), with no pointer in its API.
- managed_cases: the shared conformance cases of komira_udf_spike_abi that a
  managed runtime's user code can express, with their entries in this
  runtime's `module:function` form.
"""
