"""The C libraries the one-definition gate (`:one_definition`, BUCK) links whole.

A Mojo executable links its C libraries as static archives, one after the
other (tools/build/mojo/defs.bzl, `_link_tail`). The linker takes an archive
member only to resolve a symbol still undefined, so when two archives define
the same global symbol the first one wins and the second is silently left
out: a duplicate definition never fails a Mojo build. The gate links every
library below with `--whole-archive`, every object of every archive, so a
symbol defined twice fails its link with `duplicate symbol`.

`SRC_C_LIBRARIES` is every `cxx_library` of the komira cell under `src/`.
`cxx_library` (tools/build/lint/includes.bzl) refuses to declare one under
`src/` that this list does not name, so a new C library is in the gate or
its package does not load; a name here that no BUCK file declares fails the
gate's build as an unknown target.

`THIRD_PARTY_C_LIBRARIES` are the vendored C libraries a package under `src/`
links, so a first-party definition of one of their symbols is caught too.

This module loads nothing, so includes.bzl can load it.
"""

SRC_C_LIBRARIES = [
    "//src/komira_async:komira_async_posix",
    "//src/komira_async_api:komira_concurrency_pool_depth",
    "//src/komira_fs:komira_fs_posix",
    "//src/komira_libc:komira_libc_posix",
    "//src/komira_log:komira_log_holder",
    "//src/komira_metrics:komira_metrics_ea_flag",
    "//src/komira_objectstore:komira_objectstore_posix",
    "//src/komira_scan_source:komira_scan_source_inmem_id",
    "//src/komira_supervisor:komira_supervisor_proc",
]

THIRD_PARTY_C_LIBRARIES = [
    "//third_party/aws-lc:crypto",
    "//third_party/brotli:brotlidec",
    "//third_party/s2n-tls:s2n",
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
