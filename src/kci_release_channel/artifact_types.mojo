# =============================================================================
# kci_release_channel/artifact_types.mojo -- the artifact types a repository
# may carry. A closed set, shared by the declaration and credential modules.
# =============================================================================


# ── Artifact types a repository may carry. A closed set. ─────────────────────
comptime ARTIFACT_TYPE_OCI: String = "OCI"
"""Container images and other OCI artifacts. The location is the repository
prefix an artifact name is appended to."""

comptime ARTIFACT_TYPE_PYTHON: String = "PYTHON"
"""Python packages (a PEP 503 package index)."""

comptime ARTIFACT_TYPE_NPM: String = "NPM"
"""npm packages (an npm registry)."""

comptime ARTIFACT_TYPE_CONDA: String = "CONDA"
"""Conda packages (a conda channel)."""


def is_known_artifact_type(artifact_type: String) -> Bool:
    return (
        artifact_type == ARTIFACT_TYPE_OCI
        or artifact_type == ARTIFACT_TYPE_PYTHON
        or artifact_type == ARTIFACT_TYPE_NPM
        or artifact_type == ARTIFACT_TYPE_CONDA
    )


def known_artifact_types() -> String:
    return (
        String(ARTIFACT_TYPE_OCI)
        + String(", ")
        + String(ARTIFACT_TYPE_PYTHON)
        + String(", ")
        + String(ARTIFACT_TYPE_NPM)
        + String(", ")
        + String(ARTIFACT_TYPE_CONDA)
    )
