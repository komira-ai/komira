# =============================================================================
# komira_crypto/pbkdf2.mojo — PBKDF2-HMAC-SHA256 (RFC 8018 §5.2 / RFC 2898)
# =============================================================================
#
# SCRAM-SHA-256 (RFC 7677) uses `Hi(str, salt, i) =
# PBKDF2-HMAC-SHA256(str, salt, i, dkLen=32)`. Because SHA-256's hLen == the
# SCRAM dkLen == 32, the SCRAM case reduces to a single output block — but
# this function supports an arbitrary dkLen via the standard multi-block
# construction so it is reusable beyond SCRAM.
#
# Encapsulation: every public surface takes/returns Span[UInt8,_] / List /
# InlineArray — ZERO UnsafePointer crosses any boundary here. HMAC delegates
# to the AWS-LC-backed `hmac_sha256` one-shot.
# =============================================================================

from komira_crypto.hmac import hmac_sha256


# -----------------------------------------------------------------------------
# F(P, S, c, i) = U_1 XOR U_2 XOR ... XOR U_c  — RFC 8018 §5.2
#   U_1 = HMAC(P, S || INT(i))      (INT(i) = 4-byte big-endian block index)
#   U_j = HMAC(P, U_{j-1})
# Single 32-byte block (SHA-256 output width).
# -----------------------------------------------------------------------------
def _pbkdf2_block_sha256(
    password: Span[UInt8, _],
    salt: Span[UInt8, _],
    iterations: Int,
    block_index: UInt32,
) -> Array[UInt8, 32]:
    # U_1 = HMAC(password, salt || INT(block_index))
    var msg = List[UInt8]()
    for b in salt:
        msg.append(b)
    msg.append(UInt8((block_index >> 24) & 0xFF))
    msg.append(UInt8((block_index >> 16) & 0xFF))
    msg.append(UInt8((block_index >> 8) & 0xFF))
    msg.append(UInt8(block_index & 0xFF))

    var u = hmac_sha256(password, Span[UInt8](msg))
    # DEPARTURE from the transfer default: `u` is READ on the next line of the
    # loop below (it is the HMAC input for U_2), so `u^` here would be a
    # use-after-move. One 32-byte copy, once per block -- not in the iteration
    # loop, so it is O(blocks), not O(iterations).
    var acc = u.copy()  # T starts as U_1

    for _j in range(1, iterations):
        var u_next = hmac_sha256(password, Span[UInt8](u))
        for k in range(32):
            acc[k] = acc[k] ^ u_next[k]
        # u_next is dead after this: it is re-declared at the top of the next
        # iteration. Transfer, so the iteration loop stays copy-free.
        u = u_next^
    return acc^


# -----------------------------------------------------------------------------
# pbkdf2_hmac_sha256_32 — the SCRAM `Hi` shape (dkLen == 32, one block).
# -----------------------------------------------------------------------------
def pbkdf2_hmac_sha256_32(
    password: Span[UInt8, _], salt: Span[UInt8, _], iterations: Int
) -> Array[UInt8, 32]:
    """PBKDF2-HMAC-SHA256 with dkLen == 32 (a single output block).

    This is exactly SCRAM-SHA-256's `Hi(str, salt, i)` (RFC 7677 / RFC 5802
    §2.2): SaltedPassword. Validated byte-exact against the RFC 7677 §3
    4096-iteration vector.

    Raises is NOT needed (no allocation can fail meaningfully); returns the
    derived 32-byte key.
    """
    return _pbkdf2_block_sha256(password, salt, iterations, UInt32(1))


# -----------------------------------------------------------------------------
# pbkdf2_hmac_sha256 — general dkLen (RFC 6070 vectors use dkLen != 32).
# -----------------------------------------------------------------------------
def pbkdf2_hmac_sha256(
    password: Span[UInt8, _],
    salt: Span[UInt8, _],
    iterations: Int,
    dk_len: Int,
) -> List[UInt8]:
    """PBKDF2-HMAC-SHA256 producing `dk_len` bytes (RFC 8018 §5.2).

    Derived key DK = T_1 || T_2 || ... || T_l, truncated to dk_len bytes,
    where l = ceil(dk_len / hLen) and hLen == 32 (SHA-256). Each T_i =
    F(password, salt, iterations, i).

    General form for KDF reuse beyond SCRAM (SCRAM uses the 32-byte
    convenience above). Tested against the RFC 6070-style PBKDF2-HMAC-SHA256
    vectors (RFC 7914 §11 publishes SHA-256 variants).
    """
    var out = List[UInt8](capacity=dk_len if dk_len > 0 else 1)
    if dk_len <= 0:
        return out^
    # Number of full + partial 32-byte blocks needed.
    var n_blocks = (dk_len + 31) // 32
    var produced = 0
    var i: UInt32 = 1
    while produced < dk_len:
        var block = _pbkdf2_block_sha256(password, salt, iterations, i)
        var take = 32
        if dk_len - produced < 32:
            take = dk_len - produced
        for k in range(take):
            out.append(block[k])
        produced += take
        i += 1
    _ = n_blocks
    return out^
