"""komira_udf_spike_native: the native UDF runtime of
docs/design/udf_runtime_interface.md (section 1.2), test-only spike code.

- native/native_runtime.c: the runtime, a loader with no interpreter that
  verifies a native UDF library's sha256, dlopens the verified bytes, checks
  the library's describe and forwards the C ABI to its table. Its shared
  library is :native.
- code: native libraries staged as code objects (named by hex sha256 under a
  code root) and the code sets a spec names them by; the count of objects the
  dynamic loader has mapped.
- The fixture libraries the runtime loads: :native_c (C, the reference
  runtime's fixtures built as a native library) and
  //src/tests/helpers/komira_udf_spike_native_mojo:native_mojo (Mojo).
"""
