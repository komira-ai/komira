# =============================================================================
# komira_authz_api — the neutral authorization interface (package marker).
# =============================================================================
#
# The leaf package that declares the authorization seam: `AuthzPort` (can
# `principal` do `action` on `resource`?) + the `AuthzAction` /
# `AuthzResource` value types it is expressed over. It carries no
# permission-model vocabulary, so a host depends on it without dragging in an
# RBAC engine; a host with a membership store binds its own conformer.
#
# Convenience re-exports so `from komira_authz_api import AuthzPort` works (the
# submodule path `from komira_authz_api.authz_api import AuthzPort` works too).
# =============================================================================

from .authz_api import (
    AuthzPort,
    AuthzAction,
    AuthzResource,
    AllowAuthenticatedAuthz,
    DenyAllAuthz,
)
