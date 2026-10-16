# Test-only spike code: the Python UDF runtime of
# docs/design/udf_runtime_interface.md, a runtime library that runs user
# code in worker processes forked from a zygote, driven through the UDF
# runtime C ABI alone, and the engine loop that measures it (drive.mojo over
# native/drive.c). Nothing outside src/tests may depend on it.
