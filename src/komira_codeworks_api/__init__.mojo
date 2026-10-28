"""The CodeWorks HTTP surface as path classification: which plane a request path
belongs to (git wire, control, probe or unknown), which control sub-surface
(repository or review), which arm of the one CodeWorks service owns it, and which
repository a git-wire path names.

| function | does |
|---|---|
| `codeworks_plane_for` | the plane of a path: `CODEWORKS_PLANE_*` |
| `codeworks_control_surface_for` | the control sub-surface: `CODEWORKS_SURFACE_*` |
| `codeworks_owner_for` | the owning arm: `CODEWORKS_OWNER_*` |
| `codeworks_path_is_git_wire`, `codeworks_git_wire_repo_name` | the wire predicate and the one repository-name extraction |
| `codeworks_path_is_repo_control`, `codeworks_path_owned_by_review`, `codeworks_path_owned_by_git`, `codeworks_path_is_infra` | the per-surface predicates |
| `codeworks_repo_name_is_safe` | the legal-repository-name check |

Classification only: nothing here decides whether a request is allowed, and an
undeclared path classifies as unknown so a gate can deny it. No function takes or
returns a pointer.
"""

from .surface import (
    CODEWORKS_PLANE_UNKNOWN,
    CODEWORKS_PLANE_INFRA,
    CODEWORKS_PLANE_CONTROL,
    CODEWORKS_PLANE_GIT_WIRE,
    CODEWORKS_SURFACE_NONE,
    CODEWORKS_SURFACE_REPO,
    CODEWORKS_SURFACE_REVIEW,
    CODEWORKS_SERVICE,
    CODEWORKS_OWNER_NONE,
    CODEWORKS_OWNER_GIT,
    CODEWORKS_OWNER_REVIEW,
    CODEWORKS_MARKER_HEADER,
    CODEWORKS_MARKER_VALUE,
    CODEWORKS_RESOURCE_TYPE_REPO,
    CODEWORKS_RESOURCE_TYPE_REVIEW,
    CODEWORKS_GIT_SUFFIX,
    CODEWORKS_REPOS_SEGMENT,
    CODEWORKS_REVIEW_WORKSPACES_PREFIX,
    CODEWORKS_REVIEW_PREFIX,
    CODEWORKS_REVIEW_SEGMENT,
    CODEWORKS_REVIEW_POLICY_SEGMENT,
    CODEWORKS_INFRA_HEALTHZ,
    CODEWORKS_INFRA_LIVEZ,
    codeworks_plane_for,
    codeworks_control_surface_for,
    codeworks_owner_for,
    codeworks_path_is_git_wire,
    codeworks_git_wire_repo_name,
    codeworks_path_is_repo_control,
    codeworks_repo_name_is_safe,
    codeworks_path_owned_by_git,
    codeworks_path_owned_by_review,
    codeworks_path_is_infra,
)
