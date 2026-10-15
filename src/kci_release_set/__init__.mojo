# =============================================================================
# kci_release_set -- what the BUILD step and the PUBLISH step both know about a
#   release set: one artifact directory checked, the conda metadata read,
#   `release.json`, the set hash, and requirement closure by name.
# =============================================================================
#
#   closure.mojo           `undeclared_requirements`, `requirement_name`,
#                          `MOJO_COMPILER_PACKAGE`: every library requirement
#                          names another library of the set (BUILD refuses
#                          an open one; PUBLISH's closure check also pins it)
#   conda_metadata.mojo    `CondaMetadata`, `read_conda_metadata`; `LibFile`,
#                          a `lib_files` row of a library shipping native files;
#                          `DlopenRow`, a `dlopen` row of one opening a codec
#   system_libs.mojo       `system_libs`, `is_system_lib_requirement`: the
#                          conda-forge requirements a library may carry for
#                          a system library it opens (tools/build/package/
#                          system_libs.bzl), accepted by both closure checks
#   glibc_floor.mojo       `glibc_requirement`, `glibc_requirement_refusals`:
#                          the one `__glibc >=<floor>` a library shipping
#                          native files carries (the platform table's
#                          os_floor), and no other
#   member.mojo            `ReleaseMember`, `verify_member`: the per-artifact
#                          checks both verbs run, so build's early refusal and
#                          publish's re-check cannot drift apart; an OCI
#                          member's layout is verified blob by blob
#   release_manifest.mojo  `release.json` (kci.release_set major 2): the
#                          release identity (revision, platform), who
#                          produced it, render, parse, read
#   set_hash.mojo          the set hash a release is approved under: the
#                          revision, the platform and every member
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_set.conda_metadata import (
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    CondaMetadata,
    DocFile,
    DlopenRow,
    LIB_DIR,
    LIB_KIND_LINK,
    LIB_KIND_SHARED,
    LIB_KIND_STATIC,
    LibFile,
    MetaMember,
    parse_conda_metadata,
    read_conda_metadata,
)
from kci_release_set.closure import (
    MOJO_COMPILER_PACKAGE,
    requirement_name,
    undeclared_requirements,
)
from kci_release_set.member import ReleaseMember, file_sha256_hex, member_platform, verify_member
from kci_release_set.release_manifest import (
    RELEASE_MANIFEST_NAME,
    ReleaseEntry,
    ReleaseIdentity,
    ReleaseManifest,
    entries_set_hash,
    parse_release_manifest,
    read_release_manifest,
    release_entry_of,
    release_manifest_of,
    release_set_hash,
    render_release_manifest,
)
from kci_release_set.system_libs import SystemLib, is_system_lib_requirement, system_libs
from kci_release_set.glibc_floor import (
    GLIBC_PACKAGE,
    GlibcFloor,
    glibc_floor_of,
    glibc_floors,
    glibc_requirement,
    glibc_requirement_refusals,
    is_glibc_requirement,
)
from kci_release_set.set_hash import (
    SetHashLine,
    bytewise_less,
    set_hash_of_lines,
    set_hash_text,
    sort_bytewise,
)
