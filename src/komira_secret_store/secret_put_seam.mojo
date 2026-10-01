# =============================================================================
# komira_secret_store/secret_put_seam.mojo — the narrow "PUT a secret version
#   AS a caller-supplied identity" seam.
# =============================================================================
#
# WHY A SEPARATE TRAIT. Code that writes a secret version into a Secret Manager
# project it does not own (acting as an assumed role in that project) should not
# depend on the cloud client that performs the write. This trait is the
# dependency inversion: the consumer binds `SecretPutSeam`; the live conformer
# (a Secret Manager client) and any fake conform it from the package that owns
# the client (for example `komira_gcp_bridge`, whose own `SecretPutApi` has the
# identical signature so one conformer satisfies both); the binary wires the
# concrete conformer in.
#
# The bearer and the value bytes are per-call PARAMETERS, NEVER fields
# (custody — the token is held in-frame only). Value-typed surface only; ZERO
# UnsafePointer crosses the boundary.
# =============================================================================


trait SecretPutSeam(Movable, Deinitable):
    """The narrow Secret-Manager PUT seam. `put_secret_version(secret_ref,
    value_bytes, bearer_token)` — a VERSIONED PUT of the value INTO the target
    project's Secret Manager (create-secret-version semantics: the latest
    version wins; a re-PUT of the same value is store-idempotent), acting IN the
    target project AS the assumed-role `bearer_token`. RAISES on an unreachable
    / unauthorized store.

    The signature is identical to `komira_gcp_bridge.SecretPutApi`, so one live
    conformer (or fake) satisfies both with one method. The `value_bytes` are
    the plaintext the caller extracted immediately before this call; the token
    is a per-call PARAMETER (never a field)."""

    def put_secret_version(
        mut self,
        secret_ref: String,
        value_bytes: List[UInt8],
        bearer_token: String,
    ) raises:
        ...

    def add_secret_version(
        mut self,
        secret_ref: String,
        value_bytes: List[UInt8],
        bearer_token: String,
    ) raises:
        """ADD a version to a PRE-EXISTING named secret — the least-privilege
        write. Does NOT create-if-absent the container, so the acting identity
        needs ONLY `secretmanager.versions.add`
        (roles/secretmanager.secretVersionAdder) on the NAMED secret — never
        project-wide admin. Mirrors `komira_gcp_bridge.SecretPutApi.
        add_secret_version` so ONE conformer satisfies both. The container must
        be created beforehand; a NOT_FOUND here surfaces loudly."""
        ...
