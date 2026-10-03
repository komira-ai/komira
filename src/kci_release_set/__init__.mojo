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
#   release_manifest.mojo  `release.json` (kci.release_set major 2): the
#                          release identity (revision, platform), who
#                          produced it, render, parse, read
#   set_hash.mojo          the set hash a release is approved under: the
#                          revision, the platform and every member
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_set.conda_metadata import (
    CONDA_METADATA_SCHEMA,
    KIND_LIBRARY,
    KIND_METAPACKAGE,
    CondaMetadata,
    MetaMember,
    parse_conda_metadata,
    read_conda_metadata,
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
from kci_release_set.set_hash import (
    SetHashLine,
    bytewise_less,
    set_hash_of_lines,
    set_hash_text,
    sort_bytewise,
)
