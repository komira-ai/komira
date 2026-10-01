# =============================================================================
# komira_pg/scram.mojo — SCRAM-SHA-256 client driver
# =============================================================================
#
# Implements the RFC 5802 / RFC 7677 SCRAM-SHA-256 client computation on top
# of `komira_crypto`. Two hardening properties:
#   1. CSPRNG client nonce (komira_crypto.rng system_entropy), never a fixed
#      test nonce.
#   2. MANDATORY server-signature verification (constant-time): the
#      ServerSignature is computed AND enforced, and a mismatch rejects.
#   Plus: the server-nonce-prefix check (anti-MITM) lives in the driver.
#
# The `Hi` / SaltedPassword step delegates to
# `komira_crypto.pbkdf2_hmac_sha256_32`.
#
# Channel binding: we use GS2 header `n,,` (no channel binding) and the
# client-final `c=biws` (== base64("n,,")). The TLS channel already provides
# confidentiality; SCRAM-SHA-256-PLUS is a possible hardening step.
#
# Encapsulation: every public surface takes/returns Span[UInt8,_] / String /
# InlineArray — ZERO UnsafePointer crosses any boundary.
# =============================================================================

from komira_crypto.hmac import hmac_sha256, constant_time_eq_32
from komira_crypto.sha256 import sha256
from komira_crypto.base64 import base64_encode, base64_decode
from komira_crypto.pbkdf2 import pbkdf2_hmac_sha256_32
from komira_crypto.rng import system_entropy


# -----------------------------------------------------------------------------
# CSPRNG client nonce — RFC 5802 §5: a printable-ASCII random string. We
# generate 24 random bytes and base64-encode them (the base64 alphabet is a
# subset of printable ASCII and contains no ',' — the SCRAM field separator
# is a comma, so this is safe to embed in `r=`).
# -----------------------------------------------------------------------------
def make_client_nonce() raises -> String:
    """Generate a fresh CSPRNG client nonce (base64 of 24 random bytes ->
    32 printable-ASCII chars, no comma). RFC 5802 §5 requires the nonce be
    a sequence of printable ASCII excluding ','."""
    var raw = Array[UInt8, 24](fill=0)
    system_entropy(Span[UInt8](raw))
    return base64_encode(Span[UInt8](raw))


# -----------------------------------------------------------------------------
# XOR of two 32-byte buffers (ClientProof = ClientKey XOR ClientSignature)
# -----------------------------------------------------------------------------
def _xor32(
    a: Array[UInt8, 32], b: Array[UInt8, 32]
) -> Array[UInt8, 32]:
    var out = Array[UInt8, 32](fill=0)
    for i in range(32):
        out[i] = a[i] ^ b[i]
    return out^


struct ScramClientProof(Movable, Copyable):
    """Result of the SCRAM client computation.

    * client_proof_b64 — base64(ClientProof); goes into client-final `p=`.
    * server_signature — raw 32 bytes; compared against the server-final
      `v=` value (after base64-decoding the server's value).
    """

    var client_proof_b64: String
    var server_signature: Array[UInt8, 32]

    def __init__(
        out self,
        var client_proof_b64: String,
        var server_signature: Array[UInt8, 32],
    ):
        self.client_proof_b64 = client_proof_b64^
        self.server_signature = server_signature^


def compute_scram_client(
    password: String,
    salt: Span[UInt8, _],
    iterations: Int,
    auth_message: String,
) -> ScramClientProof:
    """The full RFC 5802 §3 client-side computation.

    Given the password, the server-supplied salt + iteration count, and the
    assembled AuthMessage (client-first-bare + "," + server-first + "," +
    client-final-without-proof), produce:
      * base64(ClientProof) for the client-final `p=` field.
      * the raw ServerSignature for verifying the server-final `v=`.

    NOTE: password is passed through SASLprep-as-identity (no Unicode
    normalization). ASCII passwords need no SASLprep; full SASLprep is
    not implemented.
    """
    var pw_bytes = password.as_bytes()

    # SaltedPassword = Hi(password, salt, i) — PBKDF2 (single 32B block).
    var salted = pbkdf2_hmac_sha256_32(pw_bytes, salt, iterations)

    # ClientKey = HMAC(SaltedPassword, "Client Key")
    var client_key = hmac_sha256(
        Span[UInt8](salted), String("Client Key").as_bytes()
    )

    # StoredKey = SHA256(ClientKey)
    var stored_key = sha256(Span[UInt8](client_key))

    # ClientSignature = HMAC(StoredKey, AuthMessage)
    var client_sig = hmac_sha256(
        Span[UInt8](stored_key), auth_message.as_bytes()
    )

    # ClientProof = ClientKey XOR ClientSignature
    var client_proof = _xor32(client_key, client_sig)
    var client_proof_b64 = base64_encode(Span[UInt8](client_proof))

    # ServerKey = HMAC(SaltedPassword, "Server Key")
    var server_key = hmac_sha256(
        Span[UInt8](salted), String("Server Key").as_bytes()
    )
    # ServerSignature = HMAC(ServerKey, AuthMessage)
    var server_sig = hmac_sha256(
        Span[UInt8](server_key), auth_message.as_bytes()
    )

    return ScramClientProof(client_proof_b64^, server_sig^)


def verify_server_signature(
    expected: Array[UInt8, 32], server_final_v_b64: String
) raises -> Bool:
    """Constant-time verify the server-final `v=<sig>` value against the
    locally-computed ServerSignature. MANDATORY per RFC 5802 §5 — a client
    that does not verify the server signature is vulnerable to a server
    impersonation. Raises if the server's value is malformed (wrong length);
    returns False on a mismatch (caller MUST reject the connection)."""
    var got = base64_decode(server_final_v_b64)
    if len(got) != 32:
        raise Error(
            "SCRAM: server-final v= has wrong length ("
            + String(len(got)) + " != 32 bytes)"
        )
    var got_arr = Array[UInt8, 32](fill=0)
    for i in range(32):
        got_arr[i] = got[i]
    return constant_time_eq_32(expected, got_arr)


# -----------------------------------------------------------------------------
# SCRAM message field extraction — find "key=" in a comma-separated message
# and return the value up to the next comma. (e.g. server-first "r=", "s=",
# "i="; server-final "v=", or "e=" for a SCRAM-level error.)
# -----------------------------------------------------------------------------
def scram_field(msg: String, key: String) -> String:
    """Extract the value for `key` (e.g. "r=") from a comma-separated SCRAM
    message. Returns "" if not found. The key must be at the start of the
    message or immediately after a comma (so "r=" does not match inside a
    base64 value)."""
    var mb = msg.as_bytes()
    var kb = key.as_bytes()
    var klen = len(kb)
    var n = len(mb)
    var i = 0
    while i + klen <= n:
        var matched = True
        for j in range(klen):
            if mb[i + j] != kb[j]:
                matched = False
                break
        var at_boundary = i == 0 or mb[i - 1] == UInt8(ord(","))
        if matched and at_boundary:
            var start = i + klen
            var end = start
            while end < n and mb[end] != UInt8(ord(",")):
                end += 1
            # Build an OWNED String via chr() accumulation. NOTE: do NOT use
            # `String(StringSlice(unsafe_from_utf8=Span(local_list)))` — that
            # can borrow the local list's heap buffer rather than copy it,
            # producing a dangling String whose first bytes get clobbered
            # (reused) after the local drops (empirically: the SCRAM salt's
            # first 8 bytes became spaces in the live handshake). chr()
            # accumulation guarantees an owned copy.
            var out = String()
            for k in range(start, end):
                out += chr(Int(mb[k]))
            return out^
        i += 1
    return String("")
