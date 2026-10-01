# =============================================================================
# komira_secret_store/secret_get_seam.mojo — the narrow "ACCESS a secret version
#   AS a caller-supplied identity" seam.
# =============================================================================
#
# WHY A SEPARATE TRAIT. Code that needs to read a secret version from a Secret
# Manager project it does not own (acting as an assumed role in that project)
# should not depend on the cloud client that performs the read. This trait is
# the dependency inversion: the consumer binds `SecretGetSeam`; the live
# conformer (a Secret Manager `AccessSecretVersion` client) and any fake conform
# it from the package that owns the client (for example `komira_gcp_bridge`);
# the binary wires the concrete conformer in.
#
# IDENTITY. The read is done AS the identity the caller passes (the
# `bearer_token` per-call parameter), NOT an ambient runtime identity. A store
# that reads with the ambient metadata identity reaches the wrong project for
# this use, so the caller assumes the target project's role first, then reads
# through this seam with that bearer.
#
# ONE VERB — `access_secret_version(secret_version_ref, bearer_token) -> List[UInt8]`.
# `secret_version_ref` is a full `projects/*/secrets/*/versions/*` name (or
# `.../versions/latest`). Returns the REVEALED payload bytes — held in-frame
# only; the caller must not persist them. RAISES on an unreachable /
# unauthorized store or a missing version. The bearer is a per-call PARAMETER,
# NEVER a field (custody). Value-typed surface only; ZERO UnsafePointer crosses
# the boundary.
# =============================================================================


trait SecretGetSeam(Movable, Deinitable):
    """The narrow Secret-Manager READ seam. ONE verb:
    `access_secret_version(secret_version_ref, bearer_token) -> List[UInt8]` —
    READ a secret version's plaintext payload (`projects/*/secrets/*/versions/*`,
    or `.../versions/latest` for the newest ENABLED version), acting IN the
    target project AS the assumed-role `bearer_token`. Returns the revealed
    payload bytes (held in-frame only — never persisted). RAISES on an
    unreachable / unauthorized store, a missing/destroyed version, or a missing
    accessor grant.

    The trait exists so a consumer does not depend on the cloud client that
    implements it; a live client and a fake both conform. The token is a
    per-call PARAMETER (never a field); the returned bytes are the caller's to
    zeroize/drop."""

    def access_secret_version(
        mut self,
        secret_version_ref: String,
        bearer_token: String,
    ) raises -> List[UInt8]:
        ...
