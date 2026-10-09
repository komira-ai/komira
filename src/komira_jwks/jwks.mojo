# =============================================================================
# komira_jwks/jwks.mojo — the deterministic `kid` derivation + the OKP/Ed25519
#   JWKS document renderer (the public-key HALF of the offline-verify token
#   stack: what a verifier fetches to learn the active verification keys).
# =============================================================================
#
# THE TWO PURE PRIMITIVES this file owns (no I/O, no store, no key CUSTODY — the
# signing seed never enters here; this is the PUBLIC-key side):
#
#   1. `kid_for_pubkey(pubkey) -> String` — the DETERMINISTIC key id:
#          kid = base64url_nopad( sha256(pubkey) )    (the FULL 32-byte hash)
#      A `kid` is a stable, collision-resistant NAME for a signing key, derived
#      ENTIRELY from the 32-byte Ed25519 public key. Determinism is the whole
#      point: the mint stamps `kid_for_pubkey(current_pubkey)` into every token's
#      JOSE header, and the JWKS publishes the SAME `kid` next to the SAME pubkey,
#      so a verifier matches header.kid -> the published key with ZERO coordination
#      and NO kid-persistence store (the id IS a function of the key material). We
#      hash the FULL 32-byte pubkey and do NOT truncate the base64url — a truncated
#      kid would reintroduce the collision risk the full hash exists to remove (two
#      distinct keys could then share a kid, and the verifier could select the
#      wrong one), and it buys nothing (43 base64url chars is a fine header field).
#
#   2. `render_jwks_json(keys) raises -> String` — the RFC 7517 JWK Set document for the
#      ACTIVE public-key set, as an OKP (RFC 8037) Ed25519 JWK array:
#          {"keys":[{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig",
#                    "kid":"<kid>","x":"<base64url_nopad(pubkey)>"}, ...]}
#      Rendered through `render_jwk_set` (jwk.mojo), the one JWK renderer of
#      this package. CRITICAL — a JWK for a PUBLIC key NEVER
#      carries the private `d` member (that would be the seed); this renderer
#      emits ONLY the public `x` (the pubkey). There is no code path here that
#      can see a seed, so `d` cannot be emitted by construction (the input is a
#      pubkey, full stop).
#
# WHY A SET, NOT ONE KEY (rotation as a DATA change): the renderer takes a LIST of
# `(kid, pubkey)` even when there is one active key today. Key rotation then adds a
# keyring entry (a new `(kid, pubkey)`) WITHOUT touching this renderer or the
# endpoint — the document simply grows an element, and a verifier that has cached
# the old JWKS still matches old tokens by their `kid` while new tokens match the
# new key. The dual-publish choreography (add-next / flip-current / retire) belongs
# to the keyring; this file just has to serve whatever set the keyring holds.
#
# ENCAPSULATION: `Span[UInt8, _]` (the caller-owned pubkey) / `String`
# (the kid + the JSON) in and out — ZERO UnsafePointer crosses any boundary, no
# wildcard origin. The pubkey is PUBLIC material (not a secret), so it needs no
# zeroizing handling — it is a plain `InlineArray[UInt8, 32]` in the keyring and a
# `Span` here.
# =============================================================================

from komira_crypto import sha256
from komira_encoding import base64_url_encode_nopad

from komira_jwks.jwk import Jwk, render_jwk_set


# =============================================================================
# §1 — the deterministic key id: kid = base64url_nopad(sha256(pubkey)).
# =============================================================================
def kid_for_pubkey(pubkey: Span[UInt8, _]) -> String:
    """The DETERMINISTIC key id for an Ed25519 public key:
    `base64url_nopad(sha256(pubkey))` over the FULL 32-byte hash (NO truncation).

    Determinism + full-hash are both load-bearing:
      * DETERMINISM — the mint derives the SAME kid from the SAME pubkey that the
        JWKS publishes, so a verifier matches `header.kid` to the published key
        with no coordination and no kid-store (the id is a pure function of the
        key material).
      * FULL HASH (no truncation) — a truncated kid could collide (two distinct
        keys sharing a kid), which would let a verifier select the WRONG key. The
        full 32-byte SHA-256 digest, base64url-nopad'd (43 chars), removes that
        risk and is a perfectly reasonable header-field length.

    Args:
        pubkey: The 32-byte Ed25519 public key (caller-owned; the SPKI raw form).

    Returns:
        The base64url-nopad of the SHA-256 of the pubkey (the stable `kid`).
    """
    var digest = sha256(pubkey)
    return base64_url_encode_nopad(Span[UInt8, origin_of(digest)](digest))


# =============================================================================
# §2 — the JWKS document renderer for a set of Ed25519 public keys. Each key is
#      rendered by `render_jwk_set` (jwk.mojo) as
#      {"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":..,"x":..}.
#      PUBLIC-key only — NEVER a `d` member (the seed).
# =============================================================================
def render_jwks_json(
    keys: List[Tuple[String, Array[UInt8, 32]]]
) raises -> String:
    """Render the RFC 7517 JWK Set for the ACTIVE public-key set as an OKP/Ed25519
    JWK array: `{"keys":[<jwk>, <jwk>, ...]}`, each element
    `{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"<kid>",
      "x":"<base64url_nopad(pubkey)>"}` in list order.

    PUBLIC-key document ONLY: the input is a public key, so there is nothing
    private to emit. An EMPTY set renders `{"keys":[]}` (a valid, well-formed
    empty JWK Set — a verifier fetching it simply finds no key, which is the
    honest state when no signing key is loaded).

    A SET even for one key (rotation is a DATA change): the caller passes whatever
    `(kid, pubkey)` set the keyring currently holds; adding a rotated key later is
    a new list element with no change to this renderer or the endpoint.

    Args:
        keys: The active `(kid, pubkey)` set — each `pubkey` a 32-byte Ed25519
            public key (PUBLIC material; the seed is NEVER passed here).

    Returns:
        The JWKS JSON document string.

    Raises:
        `JwksError: member "kid" is empty` if a `kid` is the empty string.
    """
    var jwks = List[Jwk](capacity=len(keys))
    for i in range(len(keys)):
        # `ref`, not a copy: the renderer only READS both halves.
        ref kid = keys[i][0]
        ref pubkey = keys[i][1]
        # The key is 32 bytes by type, so only the kid check can fail here.
        jwks.append(
            Jwk.ed25519(
                Span[UInt8, origin_of(pubkey)](pubkey),
                kid=Optional[String](kid.copy()),
                alg=Optional[String](String("EdDSA")),
                key_use=Optional[String](String("sig")),
            )
        )
    return render_jwk_set(jwks)
