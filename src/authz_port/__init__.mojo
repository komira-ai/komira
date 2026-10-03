# =============================================================================
# authz_port — the neutral authorization interface (package marker).
# =============================================================================
#
# The leaf package that declares the authorization seam: `AuthzPort` (can
# `principal` do `action` on `resource`?) + the POD `AuthzAction` /
# `AuthzResource` value types it is expressed over. It carries no
# permission-model vocabulary, so a host depends on it without dragging in an
# RBAC engine; a host with a membership store binds its own conformer.
#
# Convenience re-exports so `from authz_port import AuthzPort` works (the
# submodule path `from authz_port.authz_port import AuthzPort` works too).
# =============================================================================

from .authz_port import (
    AuthzPort,
    AuthzAction,
    AuthzResource,
    AllowAuthenticatedAuthz,
    DenyAllAuthz,
)
