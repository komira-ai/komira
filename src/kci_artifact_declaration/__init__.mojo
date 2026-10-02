# =============================================================================
# kci_artifact_declaration -- read and validate the artifact declarations:
#   the one reviewed list of what kci builds and publishes.
# =============================================================================
#
# The schema is `kci.release.v1.ArtifactDeclarations`, generated into
# `kci_artifact_declaration_proto`; this package adds no second model of it.
# `parse.mojo` reads a declarations file (textproto) into that value;
# `validate.mojo` holds the rules it must satisfy, the check against the
# channels file, and the lookups kci build / kci publish read it through.
# =============================================================================

from kci_artifact_declaration.parse import (
    parse_artifact_declarations,
    read_artifact_declarations,
)
from kci_artifact_declaration.validate import (
    KIND_CONDA_METAPACKAGE,
    KIND_CONDA_PACKAGE,
    KIND_OCI_IMAGE,
    KIND_PYTHON_WHEEL,
    artifact_type,
    buck2_label,
    build_order,
    find_declaration,
    is_buck2_label,
    is_valid_artifact_name,
    is_valid_conda_subdir,
    kind_name,
    known_kinds,
    members_of,
    validate_artifact_declarations,
    validate_declarations_against_channels,
)
