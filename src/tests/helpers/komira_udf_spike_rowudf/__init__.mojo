"""komira_udf_spike_rowudf: row-shaped UDFs (`df.map_rows(f)`) with a declared
read set, behind the C ABI of docs/design/udf_runtime_interface.md (shape
ROW). Test-only spike code.

- producer/: the read-set capture a Python SDK runs when the plan is built
  (komira_udf_readset.py: bytecode scan, `columns=[...]`, a sample run as a
  cross-check), and the step that writes the read sets of the functions the
  tests load (capture_main.py, run as a python_oracle).
- rowrt/ and pyrt/komira_udf_rowrt.py: komira-test/python-row, a runtime that
  embeds CPython (one sub-interpreter with its own GIL per context) and
  builds each row from the read set's columns only.
- engine: RowEngine and RowWorkload, the engine's call loop over N engine
  threads (native/row_engine.c), which passes only the read set's columns.
- read_sets: the producer's read sets, read back as the UDF references'
  read sets (UdfSpec.arg_names).
"""
