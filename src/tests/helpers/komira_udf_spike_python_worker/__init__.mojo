# Test-only spike code: the Python UDF runtime behind the worker transport
# of docs/design/udf_runtime_interface.md (section 5), driven through the
# UDF runtime C ABI by a proxy runtime library, and the engine loop that
# measures it (drive.mojo over native/drive.c). Nothing outside src/tests may
# depend on it.
