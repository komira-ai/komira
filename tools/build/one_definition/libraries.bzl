"""The C libraries the one-definition gate (`:one_definition`, BUCK) links whole.

A Mojo executable links its C libraries as static archives, one after the
other (tools/build/mojo/defs.bzl, `_link_tail`). The linker pulls an
archive member in only for a symbol that is still undefined, so a second
definition of a global symbol is reported only if its object is pulled in
for some other symbol; otherwise the first definition wins silently, and two
libraries that no executable links together are never compared. The gate
links every library below with `--whole-archive`, every object of every
archive, so a symbol defined twice fails its link with `duplicate symbol`.

`SRC_C_LIBRARIES` is every `cxx_library` of the komira cell under `src/`
declared through the BUCK-file global `cxx_library`
(tools/build/lint/includes.bzl), which refuses to declare one under `src/`
that this list does not name. That refusal does not see a library declared
any other way: a .bzl macro calling `native.cxx_library`, or a BUCK file that
loads `cxx_library` itself (from the prelude), which takes precedence over
the global. Such a library stays out of the gate. A name here that no BUCK
file declares fails the gate's build as an unknown target.

`THIRD_PARTY_C_LIBRARIES` are the vendored C libraries a package under `src/`
links, so a first-party definition of one of their symbols is caught too.

This module loads nothing, so includes.bzl can load it.
"""

SRC_C_LIBRARIES = [
    "//src/komira_async:komira_async_posix",
    "//src/komira_async_api:komira_concurrency_pool_depth",
    "//src/komira_crypto:komira_crypto_sha256_hw",
    "//src/komira_fs:komira_fs_posix",
    "//src/komira_libc:komira_libc_posix",
    "//src/komira_log:komira_log_holder",
    "//src/komira_metrics:komira_metrics_ea_flag",
    "//src/komira_objectstore:komira_objectstore_posix",
    "//src/komira_scan_source:komira_scan_source_inmem_id",
    "//src/komira_supervisor:komira_supervisor_proc",
    "//src/tests/helpers/komira_udf_spike_abi:komira_udf_spike_c",
    "//src/tests/helpers/komira_udf_spike_abi:komira_udf_echo",
    "//src/tests/helpers/komira_udf_spike_abi:komira_udf_echo_broken",
    "//src/tests/helpers/komira_udf_spike_pyworker:komira_udf_pyworker_drive",
    "//src/tests/helpers/komira_udf_spike_pyworker:komira_udf_pyworker_probe",
    "//src/tests/helpers/komira_udf_spike_pyworker:komira_udf_pyworker_proxy",
]

THIRD_PARTY_C_LIBRARIES = [
    "//third_party/aws-lc:crypto",
    "//third_party/brotli:brotlidec",
    "//third_party/s2n-tls:s2n",
    "//third_party/sha1collisiondetection:sha1dc",
    "//third_party/snappy:snappy",
    "//third_party/sqlite:sqlite3",
]

def one_definition_listed(name):
    """Fails unless the cxx_library `name` of the package being loaded is in
    SRC_C_LIBRARIES, when that package is in the komira cell under `src/`."""
    if get_cell_name() != "komira" or not (package_name() + "/").startswith("src/"):
        return
    label = "//{}:{}".format(package_name(), name)
    if label not in SRC_C_LIBRARIES:
        fail("cxx_library {}: not in SRC_C_LIBRARIES (tools/build/one_definition/libraries.bzl), the C libraries the one-definition gate links whole-archive; add it there".format(label))

# The owner of each vendored C library of THIRD_PARTY_C_LIBRARIES, by the
# third_party package that declares it: the mojo_library that ships its
# archives (docs/design/native_packaging.md, "What each library ships"), and
# the prefix its prefixed build gives every symbol it defines ("" when it is
# not prefixed). `owner` None: no library ships it, so no library outside
# src/tests/ may link it. A `cxx_library` under src/ needs no row: the
# library of its own package (`//src/<name>:<name>`) owns it.
#
# The Mojo-closure check of mojo_library (tools/build/mojo/native_reach.bzl)
# reads this: a library that links one of these archives, or calls one of
# their prefixed names, has the owner in its Mojo deps closure. An archive of
# a third_party package with no row here is refused, so a new vendored
# library is given its owner before anything links it. The symbol check of
# each prefixed library (`prefixed_archive_check` in its BUCK file) reads its
# `prefix` here, so the prefix refused is the one every symbol is proved to
# carry.
THIRD_PARTY_OWNERS = {
    "third_party/aws-lc": struct(owner = "//src/komira_crypto:komira_crypto", prefix = "komira_awslc_"),
    "third_party/brotli": struct(owner = "//src/komira_parquet_codec:komira_parquet_codec", prefix = ""),
    "third_party/s2n-tls": struct(owner = "//src/komira_http_core:komira_http_core", prefix = "komira_s2n_"),
    "third_party/sha1collisiondetection": struct(owner = None, prefix = ""),
    "third_party/snappy": struct(owner = "//src/komira_compression:komira_compression", prefix = "komira_snappy_"),
    "third_party/sqlite": struct(owner = "//src/komira_db_sqlite:komira_db_sqlite", prefix = ""),
}
