# =============================================================================
# kci_artifact -- read and validate the artifacts
#   (the one reviewed list of what kci builds and publishes), and render the
#   argv that builds one artifact.
# =============================================================================
#
# The schema is `kci.release.v1.Artifacts`, generated into
# `kci_artifact_proto`; this package adds no second model of it.
# kci knows no build tool by name: a file declares build systems (a program
# and its always-on args) and artifacts (a name, the build system and the
# args appended for it).
#
#   parse.mojo     the textproto reader (validates before it returns)
#   validate.mojo  the rules and the lookups
#   placeholders.mojo  the seven placeholders (`{out_dir}`, `{release_dir}`,
#                  `{platform}` and
#                  the git-derived stamp: `{revision_id}`, `{source_commit}`,
#                  `{build_number}`, `{timestamp_ms}`), `ReleaseStamp`,
#                  `BuildValues`, the one-pass substitution, file order,
#                  `manifest.json`, and the two refusals over what a build
#                  left (exactly one manifest; its `name` the artifact's)
#   render.mojo    `render_build_argv`: the argv for one artifact (pure)
#
# The build rules, in full in placeholders.mojo and the .proto: kci creates an EMPTY
# directory per artifact, in artifacts-file order, runs the rendered
# argv, and ships exactly what the ONE kci artifact manifest, `manifest.json`, left at its top describes (one
# artifact per entry; its `name` must be the artifact's). Running
# the build is `kci build`'s; the set-level checks over the built manifests
# (every artifact built, lockstep versions, metapackage last, requirement
# closure) are `kci publish`'s.
# =============================================================================

from kci_artifact.placeholders import (
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
# The full-commit-id check moved to kci_api; it stays importable from
# here so callers keep one import.
from kci_api import require_full_commit_id
from kci_artifact.parse import (
    parse_artifacts,
    read_artifacts,
)
from kci_artifact.render import render_build_argv
from kci_artifact.validate import (
    find_artifact,
    find_build_system,
    is_valid_artifact_name,
    validate_artifacts,
)
