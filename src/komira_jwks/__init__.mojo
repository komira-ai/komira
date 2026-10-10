# =============================================================================
# komira_jwks — JSON Web Keys (RFC 7517) for signature verification: the
#   public OKP (Ed25519), EC (P-256) and RSA key, its strict parser and
#   canonical renderer, the deterministic Ed25519 `kid`, and the publish-only
#   seed -> JWKS derivation.
# =============================================================================
#
# THE LINE. A token minter signs tokens whose payload is an application's own
# authorization vocabulary. That vocabulary belongs to the minter, not here.
# This package holds the part with no vocabulary at all:
#
#   * `Jwk`              — one public key: `Jwk.ed25519`, `Jwk.ec_p256`,
#                          `Jwk.rsa`, each checked (jwk.mojo).
#   * `parse_jwk` / `parse_jwk_set` — the strict parser on `komira_json`:
#                          size cap, duplicate members refused, private members
#                          refused, unsupported keys skipped with a reason
#                          (jwk_set.mojo states every rule).
#   * `render_jwk` / `render_jwk_set` / `JwkSet.render` — the canonical
#                          rendering, public members only.
#   * `kid_for_pubkey`   — kid = base64url_nopad(sha256(pubkey)), full digest.
#   * `render_jwks_json` — the OKP/Ed25519 JWK Set of `(kid, pubkey)` pairs.
#   * `jwks_json_from_seed` — seed in, that document out, WITHOUT constructing a
#                          minting keyring. See signing_jwks.mojo for why that
#                          distinction matters.
#
# It does not sign or verify tokens, and does not fetch or serve a key set.
#
# Dep closure: `komira_crypto` (sha256 / ed25519_pubkey_from_seed),
# `komira_encoding` (base64url), `komira_json` (the parser and string escaping)
# and `komira_secret_store` (the zeroizing move-only `SecretValue`). It must not
# grow a dependency on any token-minting or authorization package.
# =============================================================================

from komira_jwks.jwk import (
    JWK_CRV_ED25519,
    JWK_CRV_P256,
    JWK_KTY_EC,
    JWK_KTY_OKP,
    JWK_KTY_RSA,
    JWK_RSA_MAX_MODULUS_BYTES,
    JWK_RSA_MIN_MODULUS_BYTES,
    Jwk,
    render_jwk,
    render_jwk_set,
)
from komira_jwks.jwk_set import (
    JWKS_MAX_DOCUMENT_BYTES,
    JWKS_MAX_KEYS,
    JwkSet,
    parse_jwk,
    parse_jwk_set,
)
from komira_jwks.jwks import (
    kid_for_pubkey,
    render_jwks_json,
)
from komira_jwks.signing_jwks import (
    jwks_json_from_seed,
)
