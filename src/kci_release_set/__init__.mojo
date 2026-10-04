# =============================================================================
# kci_release_set -- what `kci build` and `kci publish` both know about a
#   release set: one artifact directory checked, the conda metadata read,
#   `release.json`, and the set hash.
# =============================================================================
#
#   conda_metadata.mojo    `CondaMetadata`, `read_conda_metadata`
#   member.mojo            `ReleaseMember`, `verify_member`: the per-artifact
#                          checks both verbs run, so build's early refusal and
#                          publish's re-check cannot drift apart
#   release_manifest.mojo  `release.json`: render, parse, read
#   set_hash.mojo          `release_set_hash`: the hash a release is approved
#                          under
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_set.conda_metadata import (
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    CondaMetadata,
    MetaMember,
    parse_conda_metadata,
    read_conda_metadata,
)
from kci_release_set.member import ReleaseMember, file_sha256_hex, verify_member
from kci_release_set.release_manifest import (
    RELEASE_MANIFEST_NAME,
    RELEASE_SET_SCHEMA,
    ReleaseEntry,
    ReleaseManifest,
    parse_release_manifest,
    read_release_manifest,
    release_entry_of,
    release_manifest_of,
    render_release_manifest,
)
from kci_release_set.set_hash import (
    SetHashLine,
    bytewise_less,
    release_set_hash,
    set_hash_of_lines,
    set_hash_text,
    sort_bytewise,
)
