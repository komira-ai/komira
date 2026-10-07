"""What libkomira_native.so.1 holds, stated once (README.md, "One shared library").

The library's BUCK target reads these lists, and so does every Mojo
package's conda package (tools/build/mojo/defs.bzl `_native_facts`): a package
whose closure links one of `ARCHIVES` requires the `komira_native` conda
package instead of carrying the C, and a package linking C that is not here
is refused. The lists cannot disagree with the library, because the library
is built from them.

Labels are cell-relative (`//src/...`), as a BUCK file in the komira cell
writes them; `native_label` gives a dependency's label in the same form.
"""

# The conda name of the package shipping lib/libkomira_native.so.1. Every
# package of a release is lockstep, so a library requires it at its own version
# and build string, like any other dependency (tools/build/package/conda.bzl).
CONDA_NAME = "komira_native"

# The `shared` C archives linked into the library (each a native_archive or a
# checked_cxx_library with native_kind = "shared").
ARCHIVES = [
    "//src/komira_async:komira_async_posix_native",
    "//src/komira_async_api:komira_concurrency_pool_depth_native",
    "//src/komira_crypto:komira_crypto_sha256_hw_native",
    "//src/komira_fs:komira_fs_posix_native",
    "//src/komira_libc:komira_libc_posix_native",
    "//src/komira_metrics:komira_metrics_ea_flag_native",
    "//src/komira_objectstore:komira_objectstore_posix_native",
    "//src/komira_scan_source:komira_scan_source_inmem_id_native",
    "//src/komira_supervisor:komira_supervisor_proc_native",
    "//third_party/aws-lc:crypto",
    "//third_party/s2n-tls:s2n",
    "//third_party/snappy:snappy",
]

# The `per_library` C archives Mojo code calls: kept out of the library. The
# conda package of the Mojo library that lists one in its `deps` ships it as
# lib/lib<target name>.a, and a program links it into its own image.
PER_LIBRARY = [
    "//src/komira_log:komira_log_holder_native",
]

# Every Mojo package whose sources call a name one of ARCHIVES defines: the
# library exports exactly those names.
CALLERS = [
    "//src/komira_async:komira_async",
    "//src/komira_async_api:komira_async_api",
    "//src/komira_avro:komira_avro",
    "//src/komira_buffer:komira_buffer",
    "//src/komira_column_kernels:komira_column_kernels",
    "//src/komira_compression:komira_compression",
    "//src/komira_crypto:komira_crypto",
    "//src/komira_fs:komira_fs",
    "//src/komira_http_client:komira_http_client",
    "//src/komira_http_core:komira_http_core",
    "//src/komira_http_server:komira_http_server",
    "//src/komira_libc:komira_libc",
    "//src/komira_log:komira_log",
    "//src/komira_metrics:komira_metrics",
    "//src/komira_objectstore:komira_objectstore",
    "//src/komira_orc:komira_orc",
    "//src/komira_parquet_codec:komira_parquet_codec",
    "//src/komira_scan_source:komira_scan_source",
    "//src/komira_supervisor:komira_supervisor",
    "//src/komira_uuid:komira_uuid",
]

def native_label(label):
    """`label` (a dependency's) as these lists write it, `//<package>:<name>`;
    None for a target outside the komira cell, which no list can name."""
    if label.cell != "komira":
        return None
    return "//{}:{}".format(label.package, label.name)
