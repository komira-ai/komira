# =============================================================================
# komira_jwks/signing_jwks.mojo — the PUBLISH-ONLY derivation: an Ed25519
#   signing seed in, the RFC 7517 JWK Set of its PUBLIC key out. No mint.
# =============================================================================
#
# ★ WHY THIS FUNCTION EXISTS, AND WHY IT IS NOT A METHOD ON A SIGNING KEYRING.
# An offline-verify token stack has two halves that need the SAME key material
# for OPPOSITE purposes:
#
#   * the SIGN half  — hold the secret seed and MINT tokens with it. A minting
#     keyring is inseparable from the application's authorization vocabulary
#     (the claims it signs), and it belongs to whoever issues tokens.
#   * the PUBLISH half — derive the PUBLIC key and render the JWK Set a verifier
#     fetches. That is Ed25519 + RFC 7517 + RFC 8037 and nothing else. It knows
#     no claim shape and no authorization vocabulary of any application.
#
# A DEPLOY TOOL NEEDS ONLY THE SECOND. Obtaining it by constructing a minting
# keyring from the seed and asking that keyring for its public keys would hand
# the tool a live MINTING capability — an object one method call away from
# forging a token — purely so it could read the public half. This function is
# that read, without that capability.
#
# It is the same TYPE-FIREWALL argument that keeps a write capability a
# distinct trait from a read capability: a caller that must not be able to
# do X should not hold a value that CAN do X, because "it does not call that
# method" is a convention and "it does not hold that type" is a proof.
#
# THE COMPOSITION. `ed25519_pubkey_from_seed` -> `kid_for_pubkey` ->
# `render_jwks_json` over a one-element set, so the rendered JSON and the kid are
# exactly what `render_jwks_json` produces for that key, and a seed shorter than
# 32 bytes fails fast. The seed is read ONLY through a per-call `Span`
# (`SecretValue.revealed_bytes()`) and never copied out as plaintext; because the
# `SecretValue` is moved in, it is zeroized when this function returns.
#
# ENCAPSULATION: a move-only zeroizing `SecretValue` in, a `String` out. ZERO
# UnsafePointer crosses the boundary; no wildcard origin.
# =============================================================================

from komira_crypto import ed25519_pubkey_from_seed
from komira_secret_store import SecretValue

from komira_jwks.jwks import kid_for_pubkey, render_jwks_json


def jwks_json_from_seed(var seed: SecretValue) raises -> String:
    """The PUBLIC RFC 7517 JWK Set for a 32-byte Ed25519 signing `seed`.

    Derives the public key from the seed (`ed25519_pubkey_from_seed`), computes
    the deterministic `kid` (`kid_for_pubkey`), and renders the one-element JWK
    Set. ONLY public material is produced — the document carries the `x` member
    and NEVER a private `d`.

    The seed is MOVED IN (this function is its last owner) and read once through
    a per-call `Span`, so no owned plaintext copy escapes and the bytes are wiped
    when it drops.

    A SET even for one key: rotation is a DATA change, so a later multi-key
    derivation adds elements here without changing the renderer or any caller.

    RAISES iff the seed is shorter than 32 bytes — the Ed25519 FFI requires >= 32.
    Fail fast and loud; never a silent short-key derivation, because a JWK Set
    built from a wrong-length seed would publish a key nothing ever signed with,
    and a verifier cannot tell "signed by a key I do not hold" from "forged".

    Args:
        seed: The 32-byte Ed25519 signing seed, zeroizing and move-only.

    Returns:
        The JWKS JSON document string.
    """
    if seed.len() < 32:
        raise Error(
            String("jwks_json_from_seed: signing seed must be >= 32 bytes (got ")
            + String(seed.len())
            + String(")")
        )
    var pubkey = ed25519_pubkey_from_seed(seed.revealed_bytes())
    var kid = kid_for_pubkey(Span[UInt8, origin_of(pubkey)](pubkey))
    var keys = List[Tuple[String, Array[UInt8, 32]]]()
    keys.append((kid^, pubkey^))
    return render_jwks_json(keys)
