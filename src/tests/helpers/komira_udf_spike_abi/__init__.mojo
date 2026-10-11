"""komira_udf_spike_abi: the UDF runtime contract of
docs/design/udf_runtime_interface.md, test-only.

- komira_udf_runtime.h, komira_udf_wire.h: the C ABI and the worker message
  header (native/layout_probe.c reports their layout to tests/test_layout).
- contract: the header's numbers and the host's error table.
- values: the column, batch and type values the binding takes and returns.
- runtime: UdfRuntime, which opens a runtime library and drives its table
  with the host's post-conditions; no pointer in its API.
- wire: the worker message header codec and the op table.
- cases, conform: the conformance cases (cases/*.json) and the runner that
  drives any runtime through UdfRuntime, knowing it only by its describe.
"""
