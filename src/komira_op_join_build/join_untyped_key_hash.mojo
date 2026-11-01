# =============================================================================
# join_untyped_key_hash -- the key hash and byte-equality helpers of the
# untyped hash tables (`JoinBuildTable_Untyped`, and the grouping and DISTINCT
# tables that share its directory)
# =============================================================================
#
# Hash formula: FNV-1a-style 64-bit with an upper-bit mix, so the salt
# fingerprint (top 16 bits) carries entropy from all of the input. Composite
# keys fold per-column hashes with `_hash_compose` (xor + rotate). The batch
# side and the storage side of one table must hash a key identically: a
# routing hash and the hash a later probe uses must never disagree.
#
# The names keep their leading underscore: they are shared by the untyped
# tables of the engine, not an API for queries.
# =============================================================================

from komira_arrow.string_column_view import StringView
from komira_counters.keyeq_census import keyeq_record, KEYEQ_JOINBUILD_UNTYPED


@always_inline
def _hash_u64(v: UInt64) -> UInt64:
    """FNV-1a-ish single-u64 hash with upper-bit mix."""
    var h = UInt64(0xCBF29CE484222325)
    h = h ^ v
    h = h * UInt64(0x100000001B3)
    h = h ^ (v >> 32)
    h = h * UInt64(0x100000001B3)
    h = h ^ (h >> 16)
    return h


@always_inline
def _hash_compose(h1: UInt64, h2: UInt64) -> UInt64:
    """Composite-key hash mix: xor + rotate."""
    var rot = (h1 << 17) | (h1 >> 47)
    return rot ^ h2


@always_inline
def _hash_decimal128(lo: UInt64, hi: UInt64) -> UInt64:
    """Hash a full 128-bit DECIMAL128 key over BOTH words.

    Folding the HI word in is REQUIRED for correctness: two distinct 128-bit
    decimals that share their low 64 bits (e.g. 5 and (1<<64)+5) must hash
    differently so they land in distinct groups / dedup buckets / join match
    sets. The prior code hashed `_hash_u64(lo)` only, silently collapsing them
    into one bucket. Shared by HashAggTable_Untyped / JoinBuildTable_Untyped /
    DistinctState_Untyped so the batch-side and storage-side decimal hashes
    stay byte-consistent within each table."""
    return _hash_compose(_hash_u64(lo), _hash_u64(hi))


# Variable-length byte hash for STRING / BINARY keys: canonical FNV-1a 64-bit.
#
# `_hash_bytes` and `_bytes_eq` take OWNED `List[UInt8]`s, which forces a
# caller to MATERIALISE the key bytes. `JoinBuildTable_Untyped` uses neither:
# it hashes and compares through borrowed views (`_hash_string_view` here,
# `slot_str_fnv1a` / `slot_str_first_diff` on `ColumnFormatStorage`), which are
# bit-identical and allocate nothing. The pair stays for the grouping and
# DISTINCT tables, which still call it.
#
# `KEYEQ_JOINBUILD_UNTYPED` is recorded by `_bytes_eq` on behalf of whichever
# table called it, so the tag aggregates join, DISTINCT and the agg combine
# arms; the join table's own recorders use the same triple, mismatched lengths
# included: `(len(FIRST argument), 0, False)`.
def _hash_bytes(bytes: List[UInt8]) -> UInt64:
    """FNV-1a 64-bit hash over a byte sequence.

    Used for varlen STRING / BINARY key cells.
    """
    var h: UInt64 = UInt64(0xCBF29CE484222325)
    var n = bytes.__len__()
    for i in range(n):
        h = h ^ UInt64(Int(bytes[i]))
        h = h * UInt64(0x100000001B3)
    h = h ^ (h >> 16)
    return h


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    """Byte-wise equality on two byte sequences. Used for varlen STRING /
    BINARY key equality (post-hash candidate verification).
    """
    var an = a.__len__()
    var bn = b.__len__()
    if an != bn:
        keyeq_record(KEYEQ_JOINBUILD_UNTYPED, an, 0, False)
        return False
    var _i = 0
    var _eq = True
    while _i < an:
        if a[_i] != b[_i]:
            _eq = False
            break
        _i += 1
    keyeq_record(KEYEQ_JOINBUILD_UNTYPED, an, _i, _eq)
    return _eq


@always_inline
def _hash_string_view[
    so: Origin[mut=False]
](sv: StringView[so]) raises -> UInt64:
    """FNV-1a 64-bit over a borrowed STRING / BINARY cell. Bit-identical to
    `_hash_bytes` above over the same bytes, and to
    `ColumnFormatStorage.slot_str_fnv1a`, which hashes the STORED copy of them:
    same seed, same prime, same byte order, same `h ^= h >> 16` final fold.
    Allocates nothing — which `_hash_bytes` cannot, because its argument IS the
    allocation.

    It resolves the byte window ONCE (`bytes_view()`), so the loop body is one
    load per byte. The FNV chain is the one `_hash_bytes` runs, which is the
    property the byte-equivalence tests assert.
    """
    var bv = sv.bytes_view()
    var h: UInt64 = UInt64(0xCBF29CE484222325)
    var n = bv.len()
    for i in range(n):
        h = h ^ UInt64(Int(bv.read_u8_at(i)))
        h = h * UInt64(0x100000001B3)
    h = h ^ (h >> 16)
    return h
