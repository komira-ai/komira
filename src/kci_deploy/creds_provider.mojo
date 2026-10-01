# =============================================================================
# kci_deploy/creds_provider.mojo -- the CREDS-PROVIDER seam of the deploy
#   library (one of the two frontend-terminated seams; the other is the
#   Reporter).
# =============================================================================
#
# The engine (`kci_iac`) takes an opaque `Creds` per verb and never mints, owns
# or inspects a credential. Where that `Creds` comes from is the frontend's
# concern, and it is one of the only two forks between frontends: a self-deploy
# CLI acts as the operator's own identity, a managed deployer binds an
# assume-role / workload-identity conformer (which lives with that deployer,
# not here).
#
# Conformers:
#   * StaticTokenCredsProvider -- a fixed token: the hermetic-test double, so an
#     assertion keys on a known value.
#   * AmbientCredsProvider     -- the self-deploy path. The caller supplies the
#     bearer it resolved (from its secret store, by a name passed as a flag);
#     an empty bearer yields `Creds.none()`, the sentinel a conformer reads as
#     "no assumed role, act as the ambient identity".
#
# This library reads no environment variable: the bearer is a parameter.
#
# ENCAPSULATION: value-typed surface (`Creds` out, `raises` for a resolution
# fault). No pointer field, no wildcard origin.
# =============================================================================

from kci_iac import Creds


trait CredsProvider(Movable, Deinitable):
    """The frontend-terminated creds seam. `provide()` resolves the opaque
    `Creds` the deploy facade threads to every engine verb. The engine never
    mints; a conformer here is the resolution authority."""

    def provide(mut self) raises -> Creds:
        """Resolve the `Creds` for this deploy invocation. Raises on a
        resolution fault."""
        ...


@fieldwise_init
struct StaticTokenCredsProvider(
    CredsProvider, Copyable, Movable, Deinitable
):
    """A `CredsProvider` that yields a fixed token: the hermetic-test double."""

    var _token: String

    def provide(mut self) raises -> Creds:
        return Creds(self._token.copy())


struct AmbientCredsProvider(
    CredsProvider, Copyable, Movable, Deinitable
):
    """A `CredsProvider` for the self-deploy path. `token` is the bearer the
    caller resolved; when it is empty, `provide()` yields `Creds.none()` (the
    ambient-identity sentinel: no assumed role). The argument is required, so a
    caller states explicitly that it has no bearer rather than inheriting one
    from its process environment."""

    var _token: String

    def __init__(out self, token: String):
        self._token = token.copy()

    def provide(mut self) raises -> Creds:
        if self._token.byte_length() == 0:
            return Creds.none()
        return Creds(self._token.copy())
