# =============================================================================
# name_similarity -- the string math under entity deduplication.
# =============================================================================
#
# Pure and deterministic: no randomness, no clock, no I/O. Four pieces.
#
#   normalize_name     the exact-match form of a name.
#   shannon_entropy    how specific a name is, in bits; a short or repetitive
#                      name is too generic to merge on similarity alone.
#   minhash_signature  a MINHASH_NUM_PERM-long signature over the character
#                      3-grams of a normalized name.
#   jaccard_estimate / lsh_candidate
#                      the fraction of signature positions two names share, and
#                      the banding test that says two names are near-identical.
#
# The hash is FNV-1a-64 with a per-permutation seed folded into the offset
# basis, so the same name always gives the same signature, on every machine.
# `pair_decision` turns a Jaccard estimate and a band collision into the tier a
# pair falls in; `dedup_resolve` (in `dedup`) applies it across candidates.
# =============================================================================

from std.math import log2


def normalize_name(name: String) -> String:
    """The exact-match form of a name.

    ASCII letters are lowercased and kept, ASCII digits are kept, every run of
    whitespace or ASCII punctuation becomes one space, and leading and trailing
    separators are dropped, so "Acme, Inc." and "  ACME  inc " both give
    "acme inc". Bytes of a multi-byte UTF-8 character are kept as they are
    (they are not case-folded), so a name in any script keeps its letters and
    two different such names do not normalize alike. Unicode punctuation is
    therefore kept, not dropped.

    Args:
        name: The surface name.

    Returns:
        The normalized name; "" when the name has no letter or digit.
    """
    var src = name.as_bytes()
    var out = List[UInt8](capacity=len(src))
    var pending_space = False
    for i in range(len(src)):
        var c = src[i]
        if c >= 65 and c <= 90:
            c += 32
        var keep = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c >= 128
        if keep:
            if pending_space and len(out) > 0:
                out.append(32)
            pending_space = False
            out.append(c)
        else:
            pending_space = True
    # SAFETY: the input is a String, so well-formed UTF-8. The only bytes
    # dropped or rewritten are ASCII, which never occur inside a multi-byte
    # sequence, so every sequence is copied whole and the output is well-formed.
    return String(unsafe_from_utf8=Span(out))


def shannon_entropy(text: String) -> Float64:
    """The Shannon entropy of the byte distribution of `text`, in bits.

    "" and a string of one repeated byte score 0.0; four distinct bytes once
    each score 2.0. A name with many distinct bytes scores high.

    Args:
        text: Usually a normalized name.

    Returns:
        The entropy in bits, 0.0 for an empty string.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n == 0:
        return 0.0
    var counts = List[Int](capacity=256)
    for _ in range(256):
        counts.append(0)
    for i in range(n):
        counts[Int(bytes[i])] += 1
    var total = Float64(n)
    var h = 0.0
    for i in range(256):
        var c = counts[i]
        if c > 0:
            var p = Float64(c) / total
            h += -p * log2(p)
    return h


# The number of permutations in a MinHash signature.
comptime MINHASH_NUM_PERM: Int = 32

# The number of bands a signature is split into: 4 rows each. Pairs whose
# Jaccard similarity is above about 0.6 share a band with high probability.
comptime LSH_NUM_BANDS: Int = 8

# The width of the character shingles.
comptime SHINGLE_K: Int = 3

comptime _FNV1A_64_OFFSET_BASIS: UInt64 = 14695981039346656037
comptime _FNV1A_64_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv1a64_seeded(seed: UInt64, shingle: List[UInt8]) -> UInt64:
    var h = (_FNV1A_64_OFFSET_BASIS ^ seed) * _FNV1A_64_PRIME
    for i in range(len(shingle)):
        h = h ^ UInt64(Int(shingle[i]))
        h = h * _FNV1A_64_PRIME
    return h


@always_inline
def _byte_lists_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _shingles(normalized: String) -> List[List[UInt8]]:
    """The distinct SHINGLE_K-byte windows of the name, padded with SHINGLE_K-1
    bytes of 0x01 at each end so a short name still has shingles and a shared
    prefix or suffix counts."""
    var src = normalized.as_bytes()
    var core = List[UInt8]()
    for _ in range(SHINGLE_K - 1):
        core.append(1)
    for i in range(len(src)):
        core.append(src[i])
    for _ in range(SHINGLE_K - 1):
        core.append(1)
    var out = List[List[UInt8]]()
    var start = 0
    while start + SHINGLE_K <= len(core):
        var sh = List[UInt8](capacity=SHINGLE_K)
        for j in range(SHINGLE_K):
            sh.append(core[start + j])
        var seen = False
        for e in range(len(out)):
            if _byte_lists_equal(out[e], sh):
                seen = True
                break
        if not seen:
            out.append(sh^)
        start += 1
    return out^


def minhash_signature(normalized: String) -> List[UInt64]:
    """The MinHash signature of a normalized name: for each of the
    MINHASH_NUM_PERM seeded hashes, the smallest hash over its shingles.

    Args:
        normalized: The output of `normalize_name`.

    Returns:
        MINHASH_NUM_PERM values; the same name always gives the same ones.
    """
    var shingles = _shingles(normalized)
    var sig = List[UInt64](capacity=MINHASH_NUM_PERM)
    # An odd multiplier, so distinct permutation indexes give distinct seeds.
    var golden = UInt64(0x9E3779B97F4A7C15)
    for p in range(MINHASH_NUM_PERM):
        var seed = UInt64(p) * golden + 1
        var mn = UInt64(0xFFFFFFFFFFFFFFFF)
        for s in range(len(shingles)):
            var h = _fnv1a64_seeded(seed, shingles[s])
            if h < mn:
                mn = h
        sig.append(mn)
    return sig^


def jaccard_estimate(sig_a: List[UInt64], sig_b: List[UInt64]) -> Float64:
    """The fraction of positions at which two signatures agree: the MinHash
    estimate of the Jaccard similarity of the two shingle sets.

    Args:
        sig_a: A signature.
        sig_b: A signature of the same length.

    Returns:
        A value in [0, 1]; 0.0 for empty signatures or signatures of different
        lengths.
    """
    var n = len(sig_a)
    if n == 0 or len(sig_b) != n:
        return 0.0
    var agree = 0
    for i in range(n):
        if sig_a[i] == sig_b[i]:
            agree += 1
    return Float64(agree) / Float64(n)


def lsh_candidate(sig_a: List[UInt64], sig_b: List[UInt64]) -> Bool:
    """True when some band of the two signatures is identical: the cheap test
    for a near-identical pair.

    Args:
        sig_a: A signature.
        sig_b: A signature of the same length.

    Returns:
        False for empty signatures or signatures of different lengths.
    """
    var n = len(sig_a)
    if n == 0 or len(sig_b) != n:
        return False
    var rows_per_band = n // LSH_NUM_BANDS
    if rows_per_band == 0:
        rows_per_band = 1
    var band = 0
    while band < LSH_NUM_BANDS:
        var base = band * rows_per_band
        if base >= n:
            break
        var band_eq = True
        var r = 0
        while r < rows_per_band and (base + r) < n:
            if sig_a[base + r] != sig_b[base + r]:
                band_eq = False
                break
            r += 1
        if band_eq:
            return True
        band += 1
    return False


# `pair_decision`: too different to merge or ask about.
comptime PAIR_NONE: Int = 0

# `pair_decision`: similar enough to merge without a judgment (tier 2).
comptime PAIR_MERGE: Int = 2

# `pair_decision`: close enough that a judgment should decide (tier 3).
comptime PAIR_ESCALATE: Int = 3


def pair_decision(
    jaccard: Float64,
    band_collision: Bool,
    jaccard_merge: Float64,
    jaccard_escalate: Float64,
) -> Int:
    """The tier a candidate pair falls in, given its similarity.

    A pair merges only when a band collides and its Jaccard estimate is at or
    above `jaccard_merge`. Any other pair at or above `jaccard_escalate` is
    escalated for a judgment, including a pair whose estimate reaches the merge
    floor without a band collision: that is not strong enough to merge on its
    own and not weak enough to ignore. Anything lower is `PAIR_NONE`.

    Args:
        jaccard: The `jaccard_estimate` of the pair.
        band_collision: The `lsh_candidate` result for the pair.
        jaccard_merge: The auto-merge floor.
        jaccard_escalate: The escalation floor.

    Returns:
        `PAIR_MERGE`, `PAIR_ESCALATE` or `PAIR_NONE`.
    """
    if band_collision and jaccard >= jaccard_merge:
        return PAIR_MERGE
    if jaccard >= jaccard_escalate:
        return PAIR_ESCALATE
    return PAIR_NONE
