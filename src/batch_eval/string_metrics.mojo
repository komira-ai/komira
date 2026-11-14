# =============================================================================
# string_metrics: byte-level string measures
# =============================================================================
#
# Trimming, UTF-8 character counts and the edit-distance and similarity
# functions (Levenshtein, Damerau-Levenshtein, Hamming, Jaro, Jaro-Winkler,
# Jaccard) the string-function arms of the projection evaluator call per row.
# =============================================================================

from std.sys import simd_width_of


def _trim_space_bytes(s: String, strip_left: Bool, strip_right: Bool) -> List[UInt8]:
    """`trim` / `ltrim` / `rtrim` — strip the SPACE character (0x20) only.

    ⛔ SPACE, NOT "WHITESPACE", AND THAT IS MEASURED. DuckDB v1.5.3's
    one-argument `trim` leaves tabs and newlines ON the string:
    `trim(e'\t  hi  \t')` comes back with both tabs. A kernel written against
    an `isspace` intuition would strip them and disagree with DuckDB on every
    value carrying one — a divergence no ASCII-letters fixture would show.

    Byte-wise is exact here for a reason `upper`/`lower` do NOT get to use
    (`unicode_case.mojo` has to decode): 0x20 can never occur inside a
    multi-byte UTF-8 sequence, whose bytes are all >= 0x80, so a byte-wise
    test for it cannot fire in the middle of a character.
    """
    var b = s.as_bytes()
    var n = len(b)
    var lo = 0
    var hi = n
    if strip_left:
        while lo < hi and b[lo] == 0x20:
            lo += 1
    if strip_right:
        while hi > lo and b[hi - 1] == 0x20:
            hi -= 1
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(b[i])
    return out^


def _utf8_char_count(b: Span[UInt8, _]) -> Int:
    """`length(s)` — the CODEPOINT count, which is what DuckDB's `length`
    returns (measured: `length('héllo')` = 5 while `strlen('héllo')` = 6).

    Counts every byte that is NOT a UTF-8 continuation byte (`0b10xxxxxx`,
    i.e. `0x80..0xBF`). That is exact for well-formed UTF-8 and needs no
    decode, no table and no allocation — so unlike `upper`/`lower` this
    member has NO divergence from DuckDB to state.

    ⭐ TAKES A BORROWED `Span[UInt8]`, NOT A `String`. Callers hand it
    `StringArray.get_span(i)` — a zero-copy view over the Arrow data buffer.
    Taking a `String` forced every caller through `StringArray.get(i)`, which
    materialises an OWNING `String` per row (a `List[UInt8]` heap allocation,
    a byte-at-a-time `ByteView.copy_to`, a second heap allocation + memcpy in
    the `String` ctor, then two frees). On ClickBench Q27
    (`avg(length(url))`) that per-row materialisation was 1420 ms of a 3555 ms
    query — 40% of the wall — for an algorithm that reads each byte once.
    DuckDB never copies a string byte at all: its `string_t` points straight
    into the decompressed Parquet page
    (`extension/parquet/reader/string_column_reader.cpp:69-77`).

    ⚠ The algorithm itself is byte-for-byte DuckDB's
    (`src/include/duckdb/function/scalar/string_common.hpp:25-34`:
    `length += IsCharacter(c)` where `IsCharacter(c) = (c & 0xc0) != 0x80`),
    so the gap this signature closes was never the arithmetic.
    """
    var n = len(b)
    var count = 0
    var i = 0
    # ⭐ THE COUNT IS A BRANCHLESS SIMD REDUCTION, NOT A PER-BYTE `if`.
    # DuckDB writes the same arithmetic as `length += IsCharacter(c)` — an
    # unconditional ADD of a 0/1 predicate (`string_common.hpp:25-34`), which
    # clang auto-vectorises. The Mojo spelling `if (b[i] & 0xC0) != 0x80:
    # count += 1` is a BRANCH, and the compiler does not turn it back into a
    # reduction — so this kernel walked 7.43 GB of `url` one scalar byte at a
    # time on ClickBench Q27. The vector form is the same predicate
    # (`(c & 0xC0) != 0x80`) reduced `simd_width_of[uint8]` bytes at a time;
    # the scalar tail below is the identical expression, so the two halves
    # cannot disagree about what a character is.
    #
    # ⚠ THE `reduce_add` ACCUMULATOR IS `uint8` AND THAT IS SAFE ONLY BECAUSE
    # THE VECTOR IS NARROWER THAN 256 LANES. Each lane contributes 0 or 1, so
    # the lane sum is at most `W`; `simd_width_of[uint8]` is 16 on arm64 and
    # 32/64 on x86 AVX2/AVX-512, all far below the 255 an unsigned byte holds.
    # A hypothetical 256-lane target would need a wider accumulator.
    comptime W = simd_width_of[DType.uint8]()
    var simd_end = (n // W) * W
    if simd_end > 0:
        # SAFETY: `b` is a borrowed `Span[UInt8]` whose origin the signature
        # carries, so the pointer cannot outlive the data buffer; every load
        # is inside `[0, simd_end)` and `simd_end <= n == len(b)`. No pointer
        # escapes this function (module-internal SIMD
        # with a concrete origin).
        var p = b.unsafe_ptr()
        var cont = SIMD[DType.uint8, W](0x80)
        var mask_c0 = SIMD[DType.uint8, W](0xC0)
        while i < simd_end:
            var v = p.load[width=W](i)
            count += Int((v & mask_c0).ne(cont).cast[DType.uint8]().reduce_add())
            i += W
    while i < n:
        if (b[i] & 0xC0) != 0x80:
            count += 1
        i += 1
    return count


def _levenshtein_bytes(a: String, b: String) -> Int:
    """`levenshtein(a, b)` — insert/delete/substitute edit distance over BYTES.

    ⛔ BYTES, NOT CHARACTERS, AND THAT IS MEASURED. DuckDB v1.5.3:
    `levenshtein('é','')` = 2 (one CHARACTER, two bytes) and
    `levenshtein('😀','x')` = 4. Every textbook writes this over characters and
    a character kernel is right on all of ASCII.

    Two rolling rows, so the working set is O(min-ish) rather than O(n*m) —
    the DP itself is the classic one and there is nothing clever in it.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0:
        return m
    if m == 0:
        return n
    var prev = List[Int](capacity=m + 1)
    var cur = List[Int](capacity=m + 1)
    for j in range(m + 1):
        prev.append(j)
        cur.append(0)
    for i in range(1, n + 1):
        cur[0] = i
        for j in range(1, m + 1):
            var sub = prev[j - 1]
            if ab[i - 1] != bb[j - 1]:
                sub += 1
            var best = prev[j] + 1
            if cur[j - 1] + 1 < best:
                best = cur[j - 1] + 1
            if sub < best:
                best = sub
            cur[j] = best
        for j in range(m + 1):
            prev[j] = cur[j]
    return prev[m]


def _damerau_levenshtein_bytes(a: String, b: String) -> Int:
    """`damerau_levenshtein(a, b)` — UNRESTRICTED Damerau-Levenshtein, BYTES.

    ⛔⛔ NOT THE OPTIMAL STRING ALIGNMENT DISTANCE, AND DuckDB SETTLES IT.
    MEASURED on v1.5.3: `damerau_levenshtein('ca','abc')` = **2**. OSA — the
    two-row variant that merely adds a transposition arm to the Levenshtein
    recurrence — answers **3** there, because it forbids editing a substring
    it has already transposed. The two agree on `('ab','ba')` = 1, on
    `('kitten','sitting')` = 3 and on most short inputs, so `('ca','abc')` is
    the smallest witness and it is in this file's fixture for that reason.

    The unrestricted algorithm needs a LAST-OCCURRENCE table over the alphabet
    (`da` below) and a full (n+2) x (m+2) matrix with a sentinel row/column
    holding `INF`. Because this kernel is BYTE-based the alphabet is closed at
    256, so `da` is a fixed array and not a hash map — the byte reading is the
    cheap implementation as well as the correct one.

    Reference: Damerau (1964) / Lowrance-Wagner (1975). `d[i+1][j+1]` is the
    distance between the first `i` bytes of `a` and the first `j` of `b`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0:
        return m
    if m == 0:
        return n
    var inf = n + m
    # `da[c]` = the largest i such that a[i-1] == c, so far. 0 = "not seen".
    var da = List[Int](capacity=256)
    for _c in range(256):
        da.append(0)
    # Row-major (n+2) x (m+2), flattened.
    var w = m + 2
    var d = List[Int](capacity=(n + 2) * w)
    for _e in range((n + 2) * w):
        d.append(0)
    d[0 * w + 0] = inf
    for i in range(0, n + 1):
        d[(i + 1) * w + 0] = inf
        d[(i + 1) * w + 1] = i
    for j in range(0, m + 1):
        d[0 * w + (j + 1)] = inf
        d[1 * w + (j + 1)] = j
    for i in range(1, n + 1):
        var db = 0
        for j in range(1, m + 1):
            # ⚠ `k` INDEXES ON `b[j-1]`, NOT ON `a[i-1]`. The two lines
            # below are the pair the Lowrance-Wagner recurrence is easiest to
            # transcribe backwards: `k` is where THIS COLUMN'S character last
            # occurred in `a`, `l` is where THIS ROW'S character last matched
            # in `b`. Swapping them still returns a plausible small integer.
            var k = da[Int(bb[j - 1])]
            var l = db
            var cost = 1
            if ab[i - 1] == bb[j - 1]:
                cost = 0
                db = j
            var best = d[i * w + j] + cost
            var ins = d[(i + 1) * w + j] + 1
            if ins < best:
                best = ins
            var dele = d[i * w + (j + 1)] + 1
            if dele < best:
                best = dele
            # THE TRANSPOSITION ARM — the whole difference from OSA. `k` is
            # where `b[j-1]` last occurred in `a`, `l` is where `a[i-1]` last
            # matched in `b`; the block between them is jumped in one edit
            # plus the cost of skipping what lies inside it.
            var trans = d[k * w + l] + (i - k - 1) + 1 + (j - l - 1)
            if trans < best:
                best = trans
            d[(i + 1) * w + (j + 1)] = best
        da[Int(ab[i - 1])] = i
    return d[(n + 1) * w + (m + 1)]


def _hamming_bytes(a: String, b: String) raises -> Int:
    """`hamming(a, b)` — the number of BYTE positions at which they differ.

    ⛔ IT RAISES ON TWO INPUTS THE REST OF THIS FAMILY ACCEPTS, and both
    messages mirror DuckDB v1.5.3 verbatim:
      * UNEQUAL LENGTHS — `hamming('abc','abcd')`. The comparison is on BYTES,
        so `hamming('é','e')` raises there too, even though both operands are
        exactly one CHARACTER.
      * TWO EMPTY STRINGS — `hamming('','')`. This is the surprising one:
        `levenshtein('','')` is 0 and "count the differing positions" of two
        empty sequences is naturally 0, so a kernel that answered 0 would look
        right AND would accept a call the parity target rejects.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    if n != len(bb):
        raise Error(
            "PipelineCompiler: hamming() — Strings must be of equal length!"
        )
    if n == 0:
        raise Error(
            "PipelineCompiler: hamming() — Strings must be of length > 0!"
        )
    var diff = 0
    for i in range(n):
        if ab[i] != bb[i]:
            diff += 1
    return diff


def _jaro_bytes(a: String, b: String) -> Float64:
    """`jaro_similarity(a, b)` — the Jaro similarity over BYTES, in [0, 1].

    ⛔ BYTES, NOT CHARACTERS, AND IT IS MEASURED. DuckDB v1.5.3:
    `jaro_similarity('Ünïcodé','Unicode')` = 0.65714285714285714. `'Ünïcodé'`
    is SEVEN characters and TEN bytes; the byte reading finds 4 matches over
    (10, 7) and answers (4/10 + 4/7 + 4/4)/3 = 0.65714..., while a character
    kernel finds 4 over (7, 7) and answers 0.71428... — right on all of ASCII,
    wrong on the first row that is not, this repo's standing defect shape.

    ⚠ AN EMPTY OPERAND ANSWERS 0 AND DOES NOT RAISE, unlike `_hamming_bytes`
    and unlike `_jaccard_bytes` below. MEASURED: `jaro_similarity('','')` = 0
    and `jaro_similarity('abc','')` = 0. "Two empty strings are identical, so
    1" is the plausible wrong reading and this is the row that refutes it.

    The matching window is `max(n, m) // 2 - 1`, floored at 0, and a
    TRANSPOSITION is a pair of matched bytes whose match ORDER differs; `t` is
    half that count, which is why the third term is `(m - t) / m`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0 or m == 0:
        return Float64(0.0)
    var window = (max(n, m) // 2) - 1
    if window < 0:
        window = 0
    var a_hit = List[Bool](capacity=n)
    for _ in range(n):
        a_hit.append(False)
    var b_hit = List[Bool](capacity=m)
    for _ in range(m):
        b_hit.append(False)
    var matches = 0
    for i in range(n):
        var lo = i - window
        if lo < 0:
            lo = 0
        var hi = i + window + 1
        if hi > m:
            hi = m
        for j in range(lo, hi):
            if b_hit[j]:
                continue
            if ab[i] != bb[j]:
                continue
            a_hit[i] = True
            b_hit[j] = True
            matches += 1
            break
    if matches == 0:
        return Float64(0.0)
    # HALF-TRANSPOSITIONS: walk the two matched subsequences in parallel and
    # count the positions where they disagree. `t` is that count // 2.
    var half = 0
    var k = 0
    for i in range(n):
        if not a_hit[i]:
            continue
        while not b_hit[k]:
            k += 1
        if ab[i] != bb[k]:
            half += 1
        k += 1
    var mm = Float64(matches)
    var t = Float64(half // 2)
    return (mm / Float64(n) + mm / Float64(m) + (mm - t) / mm) / Float64(3.0)


def _jaro_winkler_bytes(a: String, b: String) -> Float64:
    """`jaro_winkler_similarity(a, b)` — `_jaro_bytes` plus Winkler's prefix
    boost, over BYTES.

    ⛔⛔ TWO CONSTANTS HERE ARE MEASURED AND A KERNEL THAT GETS EITHER WRONG IS
    RIGHT ON EVERY TEXTBOOK EXAMPLE:

      * **THE PREFIX LENGTH IS CAPPED AT 4.** v1.5.3:
        `jaro_similarity('abcdefgh','abcdeXXX')` = 0.75 and
        `jaro_winkler_similarity` of that pair = 0.84999999999999998. The
        common prefix is FIVE bytes; 0.75 + 4*0.1*0.25 = 0.85, and an uncapped
        L answers 0.875.
      * **THE BOOST IS GATED ON `j > 0.7`.** v1.5.3:
        `jaro_similarity('abcde','abzzzzzzz')` = 0.54074074074074074 and
        `jaro_winkler_similarity` of the SAME pair = 0.54074074074074074 —
        no boost at all despite a two-byte common prefix. Ungated it answers
        0.6326.... The neighbouring pair `('abcde','abcxx')` DOES get the
        boost (0.73333333333333339 -> 0.81333333333333335, a delta of exactly
        3 * 0.1 * (1 - j)), so the two rows pin the gate from both sides.

    ⚠ The prefix is counted in BYTES, like the matching.
    """
    var j = _jaro_bytes(a, b)
    if j <= Float64(0.7):
        return j
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var lim = min(min(len(ab), len(bb)), 4)
    var pref = 0
    for i in range(lim):
        if ab[i] != bb[i]:
            break
        pref += 1
    return j + Float64(pref) * Float64(0.1) * (Float64(1.0) - j)


def _jaccard_bytes(a: String, b: String) raises -> Float64:
    """`jaccard(a, b)` — the Jaccard index of the two operands' BYTE SETS.

    ⛔⛔ A SET OF SINGLE BYTES, NOT A SET OF BIGRAMS, AND THAT IS THE ONE THING
    A "jaccard over strings" IMPLEMENTATION USUALLY GETS OTHERWISE. MEASURED
    v1.5.3: `jaccard('martha','marhta')` = **1** — the two share every
    character and differ only in ORDER — and `jaccard('abc','cba')` = **1** for
    the same reason. A bigram kernel answers 0.2 and 0 there. `jaccard('aab',
    'ab')` = 1 (a SET ignores multiplicity) and `jaccard('abcd','ab')` = 0.5 =
    |{a,b}| / |{a,b,c,d}|.

    ⛔ IT RAISES ON AN EMPTY OPERAND WHERE `_jaro_bytes` ANSWERS 0, and the
    message mirrors v1.5.3 verbatim: `jaccard('abc','')` ->
    `Invalid Input Error: Jaccard Function: An argument too short!`. Answering
    0 — or 1, on "two empty sets are equal" — accepts a call the parity target
    REJECTS, the divergence that looks like extra capability.

    ⚠ CASE-SENSITIVE: `jaccard('ABC','abc')` = 0. The set is over raw bytes and
    nothing is folded.

    ⚠ 256 FLAGS AND NOT A HASH SET, precisely BECAUSE the unit is the BYTE —
    the alphabet is 0..255 and is closed, the same reason
    `_damerau_levenshtein_bytes` carries a 256-entry last-occurrence table.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) == 0 or len(bb) == 0:
        raise Error(
            "PipelineCompiler: jaccard() — An argument too short!"
        )
    var in_a = List[Bool](capacity=256)
    var in_b = List[Bool](capacity=256)
    for _ in range(256):
        in_a.append(False)
        in_b.append(False)
    for i in range(len(ab)):
        in_a[Int(ab[i])] = True
    for i in range(len(bb)):
        in_b[Int(bb[i])] = True
    var inter = 0
    var union = 0
    for v in range(256):
        if in_a[v] and in_b[v]:
            inter += 1
        if in_a[v] or in_b[v]:
            union += 1
    # ⚠ `union` CANNOT BE ZERO HERE — both operands are non-empty, so each
    # contributes at least one byte. The refusal above is what establishes it.
    return Float64(inter) / Float64(union)


def _utf8_first_codepoint(b: Span[UInt8, _], empty: Int) -> Int:
    """`ascii(s)` / `unicode(s)` — the SCALAR VALUE of the first character.

    ⭐ TAKES A BORROWED `Span[UInt8]` for the same reason `_utf8_char_count`
    above does — see that docstring for the measurement.

    ⛔ IT DECODES, IT DOES NOT READ A BYTE. MEASURED on DuckDB v1.5.3:
    `ascii('é')` = 233 and `ascii('😀')` = 128512, i.e. the full Unicode scalar
    value however many UTF-8 bytes it occupies. Returning `b[0]` would answer
    195 and 240 — plausible small integers, and CORRECT FOR ALL OF ASCII, so
    an ASCII-only fixture cannot tell the two implementations apart.

    ⚠ `empty` IS A PARAMETER BECAUSE THE TWO CALLERS DISAGREE THERE AND
    NOWHERE ELSE. MEASURED: `ascii('')` = 0 and `unicode('')` = `ord('')` =
    -1. Every non-empty input gives both the same number, so folding them into
    one op would be right on every test that has no empty string in it.

    Malformed input is decoded permissively rather than raised on: a
    continuation byte in the lead position contributes its own low bits and a
    truncated sequence stops at the end of the buffer. This kernel's job is
    not UTF-8 validation, and a raise here would turn a data-quality problem in
    one row into a failed query.
    """
    var n = len(b)
    if n == 0:
        return empty
    var b0 = Int(b[0])
    if b0 < 0x80:
        return b0
    # Lead-byte length and initial payload bits.
    var extra = 0
    var cp = 0
    if (b0 & 0xE0) == 0xC0:
        extra = 1
        cp = b0 & 0x1F
    elif (b0 & 0xF0) == 0xE0:
        extra = 2
        cp = b0 & 0x0F
    elif (b0 & 0xF8) == 0xF0:
        extra = 3
        cp = b0 & 0x07
    else:
        # Not a valid lead byte (a stray continuation byte, or 0xF8..0xFF).
        return b0 & 0x3F
    for i in range(1, extra + 1):
        if i >= n:
            break
        cp = (cp << 6) | (Int(b[i]) & 0x3F)
    return cp
