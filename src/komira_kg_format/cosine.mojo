# =============================================================================
# cosine -- brute-force cosine ranking over a packed-embedding column.
# =============================================================================
#
# `cosine_topk` scores every row of a packed-embedding string column against a
# query vector and returns the best `k` rows. It is O(rows) per query and needs
# no index and no engine.
#
# READ-PATH RULE: a cell holds little-endian f32 bytes, and those bytes routinely
# contain 0x00 (a 0.0 component is four of them). The kernel reads a cell through
# `StringArray.get_span`, the length-based byte view, and `unpack_embedding_bytes`.
# It must never read a cell through `StringArray.get`, which returns a
# null-terminated string and would cut the vector at the first 0x00.
#
# SIMD: the three reductions a cosine needs, dot(a,b), dot(a,a) and dot(b,b), are
# computed in one fused pass with `simd_width_of[DType.float64]()`-wide
# accumulators and a scalar tail. The raw pointer arithmetic is confined to one
# private helper; no pointer crosses the public API.
#
# DEFINED RESULTS (a score is never NaN):
#   * a zero-norm operand (all zero, or empty) scores 0.0;
#   * a result that is not finite (a NaN or infinite component, or squares that
#     overflow f64) scores 0.0;
#   * the result is clamped to [-1.0, 1.0], because dot / (|a| * |b|) can round
#     to a hair outside it (a vector against itself can score 1.0000000000000002).
#
# ORDER: top-k is ordered by score descending; rows with equal scores rank the
# lower row index first. The order depends only on the scores and the row
# indexes, so it is reproducible under any evaluation order.
# =============================================================================

from std.math import isfinite, sqrt
from std.sys import simd_width_of

from komira_arrow.string_array import StringArray
from komira_buffer.memory_region import MemoryRegion

from .embedding import unpack_embedding_bytes


@fieldwise_init
struct Hit(Copyable, Movable):
    """A scored row: its index in the source column and its cosine score.

    Fields:
        row: Zero-based row index in the scored embedding column.
        score: Cosine similarity against the query vector, in [-1.0, 1.0]
            (exactly 0.0 when either operand has zero norm or the result is not
            finite).
    """

    var row: Int
    var score: Float64


@always_inline
def _simd_dot_and_norms(
    a: UnsafePointer[Float64, _],
    b: UnsafePointer[Float64, _],
    n: Int,
) -> Tuple[Float64, Float64, Float64]:
    """Fused dot(a,b), dot(a,a), dot(b,b) over `n` contiguous f64 elements.

    Args:
        a: The first operand's `n` contiguous f64 values. The origin is inferred
            at the call site from a live `List[Float64]`.
        b: The second operand's `n` contiguous f64 values.
        n: The element count; both operands hold at least `n` elements.

    Returns:
        `(dot_ab, norm_a_sq, norm_b_sq)`.
    """
    # SAFETY: `a` and `b` point into `List[Float64]` buffers that the caller
    # keeps alive across this call and that hold at least `n` elements (the
    # caller passes n = min(len(a), len(b)) > 0). The vector loads read
    # `[i, i + width)` only while `i < simd_end <= n`, and the scalar tail reads
    # `[simd_end, n)`, so no load reaches element `n`. Neither pointer escapes:
    # the function returns scalars.
    comptime width = simd_width_of[DType.float64]()

    var dot_v = SIMD[DType.float64, width](0.0)
    var na_v = SIMD[DType.float64, width](0.0)
    var nb_v = SIMD[DType.float64, width](0.0)

    var simd_end = (n // width) * width
    var i = 0
    while i < simd_end:
        var av = a.load[width=width](i)
        var bv = b.load[width=width](i)
        dot_v += av * bv
        na_v += av * av
        nb_v += bv * bv
        i += width

    var dot = dot_v.reduce_add()
    var na = na_v.reduce_add()
    var nb = nb_v.reduce_add()

    while i < n:
        var av = a.load[width=1](i)
        var bv = b.load[width=1](i)
        dot += av * bv
        na += av * av
        nb += bv * bv
        i += 1

    return (dot, na, nb)


def cosine(a: List[Float64], b: List[Float64]) -> Float64:
    """Cosine similarity of two f64 vectors: dot / (|a| * |b|).

    Compares the overlapping prefix `min(len(a), len(b))`; a caller that needs
    equal dimensions checks them first. The dot product and both norms are
    computed in one SIMD pass.

    Args:
        a: The first vector.
        b: The second vector.

    Returns:
        The similarity in [-1.0, 1.0]. Exactly 0.0 when either operand has zero
        norm (all zero, or empty) or when the result is not finite.
    """
    var n = min(len(a), len(b))
    if n == 0:
        return 0.0

    var sums = _simd_dot_and_norms(a.unsafe_ptr(), b.unsafe_ptr(), n)
    var dot = sums[0]
    var na = sums[1]
    var nb = sums[2]

    if na == 0.0 or nb == 0.0:
        return 0.0
    var c = dot / (sqrt(na) * sqrt(nb))
    if not isfinite(c):
        return 0.0
    if c > 1.0:
        return 1.0
    if c < -1.0:
        return -1.0
    return c


def cosine_topk[
    K: MemoryRegion
](emb_col: StringArray[K], query: List[Float64], k: Int) raises -> List[Hit]:
    """Brute-force top-k cosine ranking of a packed-embedding column.

    Each row is read with the length-based `get_span`, unpacked with
    `unpack_embedding_bytes` and scored against `query` with `cosine`. A null
    cell has no vector and scores 0.0.

    The caller must check the graph's embedding dimension against the manifest
    first (`KgManifestBody.check_embedding_dim`, and `unpack_embedding_checked`
    for a cell): a row of another length is scored on the overlapping prefix and
    not refused.

    Parameters:
        K: The array's memory region (inferred).

    Args:
        emb_col: A string column whose cells are packed f32 embeddings.
        query: The query vector in f64.
        k: How many hits to return; clamped to the row count, and a `k` of zero
            or less returns an empty list.

    Returns:
        Up to `k` hits, score descending, equal scores ordered by lower row
        index first.
    """
    var n = len(emb_col)
    var scored = List[Hit](capacity=n)
    for r in range(n):
        var score: Float64
        if emb_col.is_null(r):
            score = 0.0
        else:
            var v = unpack_embedding_bytes(emb_col.get_span(r))
            score = cosine(query, v)
        scored.append(Hit(r, score))

    return _top_k_desc(scored^, k)


def _top_k_desc(var scored: List[Hit], k: Int) -> List[Hit]:
    """Select the top `k` hits by score descending, lower row first on a tie.

    A partial selection sort: for each of the first `min(k, n)` slots it picks
    the best remaining hit, where better means a strictly greater score or an
    equal score with a lower row index. O(n * k); no full sort. Scores are never
    NaN (see `cosine`), so the comparison is a total order.

    Args:
        scored: Every scored hit (consumed).
        k: How many to keep; clamped to `[0, len(scored)]`.

    Returns:
        The selected hits in rank order.
    """
    var n = len(scored)
    var limit = max(0, min(k, n))
    var out = List[Hit](capacity=limit)
    for slot in range(limit):
        var best = slot
        for j in range(slot + 1, n):
            var j_score = scored[j].score
            var j_row = scored[j].row
            var b_score = scored[best].score
            var b_row = scored[best].row
            if (j_score > b_score) or (j_score == b_score and j_row < b_row):
                best = j
        if best != slot:
            var tmp = scored[slot].copy()
            scored[slot] = scored[best].copy()
            scored[best] = tmp^
        out.append(scored[slot].copy())
    return out^
