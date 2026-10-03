# =============================================================================
# kci_artifact_declaration -- read and validate the artifact declarations
#   (the one reviewed list of what kci builds and publishes), and render the
#   argv that builds one artifact.
# =============================================================================
#
# The schema is `kci.release.v1.ArtifactDeclarations`, generated into
# `kci_artifact_declaration_proto`; this package adds no second model of it.
# kci knows no build tool by name: a file declares build systems (a program
# and its always-on args) and artifacts (a name, the build system and the
# args appended for it).
#
#   parse.mojo     the textproto reader (validates before it returns)
#   validate.mojo  the rules and the lookups
#   contract.mojo  the seven placeholders (`{out_dir}`, `{release_dir}`,
#                  `{platform}` and
#                  the git-derived stamp: `{revision_id}`, `{source_commit}`,
#                  `{build_number}`, `{timestamp_ms}`), `ReleaseStamp`,
#                  `BuildValues`, the one-pass substitution, file order,
#                  `manifest.json`, and the two refusals over what a build
#                  left (exactly one manifest; its `name` the declaration's)
#   render.mojo    `render_build_argv`: the argv for one artifact (pure)
#
# The contract, in full in contract.mojo and the .proto: kci creates an EMPTY
# directory per artifact, in declarations-file order, runs the rendered
# argv, and ships exactly what the ONE kci artifact manifest, `manifest.json`, left at its top describes (one
# artifact per declaration; its `name` must be the declaration's). Running
# the build is the BUILD step's; the set-level checks over the built manifests
# (every artifact built, lockstep versions, metapackage last, requirement
# closure) are the PUBLISH step's.
# =============================================================================

from kci_artifact_declaration.contract import (
    BUILD_NUMBER_PLACEHOLDER,
    KCI_MANIFEST_NAME,
    OUT_DIR_PLACEHOLDER,
    PLATFORM_PLACEHOLDER,
    RELEASE_DIR_PLACEHOLDER,
    REVISION_ID_PLACEHOLDER,
    SOURCE_COMMIT_PLACEHOLDER,
    TIMESTAMP_MS_PLACEHOLDER,
    BuildValues,
    ReleaseStamp,
    is_known_placeholder,
    known_placeholders,
    placeholders_in,
    require_manifest_name,
    require_one_manifest,
    substitute_placeholders,
)
# The full-commit-id check moved to kci_contract; it stays importable from
# here so callers keep one import.
from kci_contract import require_full_commit_id
from kci_artifact_declaration.parse import (
    parse_artifact_declarations,
    read_artifact_declarations,
)
from kci_artifact_declaration.render import render_build_argv
from kci_artifact_declaration.validate import (
    find_artifact,
    find_build_system,
    is_valid_declaration_name,
    validate_artifact_declarations,
)
