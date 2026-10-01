# =============================================================================
# komira_secret_store/secret_reap_seam.mojo — the narrow "DELETE a secret /
#   LIST secrets AS a caller-supplied identity" seam.
# =============================================================================
#
# WHY A SEPARATE TRAIT. Erasure (delete a project's secrets) and its
# verification sweep (list what is left) need Secret Manager verbs the
# `SecretPutSeam` does not carry (DeleteSecret / ListSecrets). As with the put
# seam, the consumer binds this trait and does not depend on the cloud client;
# the live conformer (a Secret Manager client) and a fake conform it from the
# package that owns the client (for example `komira_gcp_bridge`), and the
# caller supplies the assumed-role bearer.
#
# TWO VERBS — `delete_secret(secret_ref, bearer)` (idempotent on 404) and
# `list_secret_names(project, bearer) -> List[String]` (the sweep enumeration).
# Both act IN the target project AS the assumed-role `bearer` (a per-call
# PARAMETER, NEVER a field — custody). Value-typed surface only; ZERO
# UnsafePointer crosses the boundary.
# =============================================================================


trait SecretDeleteApi(Movable, Deinitable):
    """The narrow Secret-Manager DELETE + LIST seam for erasure and its
    verification sweep. The trait exists so a consumer does not depend on the
    cloud client that implements it.

    Verbs:
      * `delete_secret(secret_ref, bearer)` — DELETE the Secret CONTAINER
        (`projects/*/secrets/*`, container + all versions) AS the assumed role.
        IDEMPOTENT (a NOT_FOUND = already gone = success); RAISES on a real fault.
      * `list_secret_names(project, bearer) -> List[String]` — LIST the Secret
        resource names in `project` (`projects/*`) AS the assumed role — the sweep
        enumerates residuals. RAISES on an unreachable / unauthorized store (a
        transient must NOT read as an empty sweep — fail-loud)."""

    def delete_secret(mut self, secret_ref: String, bearer_token: String) raises:
        ...

    def list_secret_names(
        mut self, project: String, bearer_token: String
    ) raises -> List[String]:
        ...
