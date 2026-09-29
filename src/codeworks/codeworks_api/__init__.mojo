# =============================================================================
# codeworks/codeworks_api — THE CodeWorks API SURFACE declaration (package marker).
# =============================================================================
#
# The neutral leaf package that declares what CodeWorks' HTTP surface IS: the ONE
# CONTROL plane (repo CRUD + review + coordinator) and the SEPARATE git WIRE
# dataplane, plus which ARM of the ONE `codeworks` service owns each route. Carries
# ZERO Komira vocabulary and ZERO deps — pure path classification, no transport types.
#
# It answers WHICH PLANE / WHICH ARM / WHICH REPO. It never answers WHETHER ALLOWED:
# the RBAC attach points are DECLARED in the module header — point 2 (the git wire) is
# FILLED and mounted; point 1 (one catalog over all three sub-surfaces) is open by
# design, with each arm carrying its own gate today.
#
# Convenience re-exports so `from codeworks_api import codeworks_plane_for` works
# (the submodule path `from codeworks_api.codeworks_api import ...` works too).
# =============================================================================

from .codeworks_api import (
    CODEWORKS_PLANE_UNKNOWN,
    CODEWORKS_PLANE_INFRA,
    CODEWORKS_PLANE_CONTROL,
    CODEWORKS_PLANE_GIT_WIRE,
    CODEWORKS_SURFACE_NONE,
    CODEWORKS_SURFACE_REPO,
    CODEWORKS_SURFACE_REVIEW,
    CODEWORKS_SURFACE_COORDINATOR,
    CODEWORKS_SERVICE,
    # ★ THE RESPONSE ATTRIBUTION MARKER. Exported because it has exactly TWO
    # consumers and they are on opposite sides of the wire: the service STAMPS
    # it and an e2e validator READS it. One producer, no mirror — see §3b.
    CODEWORKS_MARKER_HEADER,
    CODEWORKS_MARKER_VALUE,
    CODEWORKS_OWNER_NONE,
    CODEWORKS_OWNER_GIT,
    CODEWORKS_OWNER_REVIEW,
    CODEWORKS_OWNER_COORDINATOR,
    CODEWORKS_RESOURCE_TYPE_REPO,
    CODEWORKS_RESOURCE_TYPE_REVIEW,
    CODEWORKS_GIT_SUFFIX,
    CODEWORKS_REPOS_SEGMENT,
    CODEWORKS_REVIEW_WORKSPACES_PREFIX,
    CODEWORKS_REVIEW_PREFIX,
    CODEWORKS_REVIEW_SEGMENT,
    CODEWORKS_REVIEW_POLICY_SEGMENT,
    CODEWORKS_COORD_RESERVATIONS_PATH,
    CODEWORKS_COORD_DEVICES_PATH,
    CODEWORKS_COORD_TICK_PATH,
    codeworks_plane_for,
    codeworks_control_surface_for,
    codeworks_owner_for,
    codeworks_path_is_git_wire,
    codeworks_git_wire_repo_name,
    codeworks_path_is_repo_control,
    codeworks_repo_name_is_safe,
    codeworks_path_owned_by_git,
    codeworks_path_owned_by_review,
    codeworks_path_owned_by_coordinator,
    codeworks_path_is_infra,
)
