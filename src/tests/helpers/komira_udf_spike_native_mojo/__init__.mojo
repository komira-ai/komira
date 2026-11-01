"""komira_udf_spike_native_mojo: a native UDF library written in Mojo, for
the UDF runtime spike of docs/design/udf_runtime_interface.md, test-only.

It implements the runtime C ABI (komira_udf_runtime.h) directly, as a native
UDF library does (design section 1.2): the corpus fixtures of the
conformance suite, in Mojo, over Arrow C Data arrays moved in without a
copy. The shared library :native_mojo exports its table through
komira_udf_native_init_v1, the symbol the native runtime
(src/tests/helpers/komira_udf_spike_native) resolves.

- _arrow: reading input arrays, building output arrays, errors.
- _fixtures: the fixture table, validate's checks, the column and ROW
  fixtures, with the catch that keeps a Mojo error from crossing the ABI.
- _table: the table's entries, the aggregate and frame fixtures, and
  native_init.
"""

from ._table import native_init
