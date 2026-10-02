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
#   contract.mojo  `{out_dir}`, `manifest.json`, the substitution, and the
#                  two refusals over what a build left (exactly one
#                  manifest; its `name` is the declaration's, exactly)
#   render.mojo    `render_build_argv`: the argv for one artifact (pure)
#
# The contract, in full in contract.mojo and the .proto: kci creates an EMPTY
# directory per artifact, runs the rendered argv, and ships exactly what the
# ONE kci artifact manifest, `manifest.json`, left at its top describes (one
# artifact per declaration; its `name` must be the declaration's). Running
# the build is `kci build`'s; the set-level checks over the built manifests
# (every artifact built, lockstep versions, metapackage last, requirement
# closure) are `kci publish`'s.
# =============================================================================

from kci_artifact_declaration.contract import (
    KCI_MANIFEST_NAME,
    OUT_DIR_PLACEHOLDER,
    placeholders_in,
    require_manifest_name,
    require_one_manifest,
    substitute_out_dir,
)
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
