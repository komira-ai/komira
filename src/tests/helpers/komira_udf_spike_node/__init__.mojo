"""komira_udf_spike_node: the Node.js UDF runtime behind the C ABI of
docs/design/udf_runtime_interface.md, test-only (see BUCK for the package).

- node_cases: the shared conformance cases (komira_udf_spike_abi/cases) as a
  Node runtime runs them: the cases a TypeScript function can express, each
  entry rewritten to the bundle's `fixtures.js#<name>`.
"""
