# =============================================================================
# komira_jwks — the PUBLIC half of an offline-verify token stack: the
#   deterministic `kid`, the RFC 7517 / RFC 8037 JWK Set renderer, and the
#   publish-only seed -> JWKS derivation.
# =============================================================================
#
# THE LINE. A token minter signs tokens whose payload is an application's own
# authorization vocabulary (which organisation, which resource, which access
# level). That vocabulary belongs to the minter, not here. This package holds the
# part with no vocabulary at all:
#
#   * `kid_for_pubkey`   — kid = base64url_nopad(sha256(pubkey)), full digest.
#   * `render_jwks_json` — the OKP/Ed25519 JWK Set (RFC 7517 + RFC 8037), public
#                          members only, never a private `d`.
#   * `jwks_json_from_seed` — seed in, that document out, WITHOUT constructing a
#                          minting keyring. See signing_jwks.mojo for why that
#                          distinction matters.
#
# Two IETF documents and a hash: anyone can use every symbol here.
#
# Dep closure: `komira_crypto` (sha256 / ed25519_pubkey_from_seed),
# `komira_encoding` (base64url) and `komira_secret_store` (the zeroizing move-only `SecretValue`). It must not
# grow a dependency on any token-minting or authorization package.
#
# `well_known.IDENTITY_JWKS_PATH` names the path an identity-token issuer serves
# its JWKS at.
# =============================================================================

from komira_jwks.jwks import (
    kid_for_pubkey,
    render_jwks_json,
)
from komira_jwks.signing_jwks import (
    jwks_json_from_seed,
)
