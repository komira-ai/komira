# =============================================================================
# offset_overflow.mojo — the Int32 variable-length offset ceiling, made LOUD.
# =============================================================================
#
# Arrow's `string` / `binary` / `list` / `map` types carry **Int32** offsets:
# `offsets[N]` is the total data-buffer length, so a column's data buffer can
# address at most `INT32_MAX == 2_147_483_647` bytes (~2 GiB). Arrow's
# `large_string` / `large_binary` / `large_list` are the SAME logical types with
# Int64 offsets and no such ceiling.
#
# WHY THIS FILE EXISTS
# --------------------
# Every producer in this tree computes its cumulative byte offset in a 64-bit
# `Int` and then NARROWS it with `Int32(offset)` when writing the offsets
# buffer. That narrowing is a silent two's-complement wrap. Past 2 GiB of data
# it produces a NEGATIVE offset, and the consequences are all quiet:
#
#   * `get_length(i) == offsets[i+1] - offsets[i]` goes garbage/negative,
#   * `get_span(i)` slices at a negative start,
#   * the array's row COUNT stays exactly right — so a row-count check, which
#     is the only check some callers run, passes clean.
#
# Example: a wide-VARCHAR join emitting ~40M output rows of 48-64 byte keys =
# 2,351,945,493 data bytes. Narrowed: 2351945493 - 2**32 = -1943021803 — a
# negative `data_length`. Output rows from ~38.35M on are unaddressable.
#
# THE GUARD SHAPE: check the TOTAL, not the narrowing.
# ----------------------------------------------------
# Every one of these producers is two-pass — pass 1 sums the output byte total
# in 64-bit `Int`, pass 2 narrows per element. So ONE `Int` comparison against
# the total, placed BEFORE pass 2 (and before the data buffer is allocated),
# is both COMPLETE (no wrapped offset is ever written) and FREE (O(1) per
# column, zero cost in the per-element loop). Guarding the per-element
# narrowing instead would put a branch in the hot loop for no extra coverage.
#
# Fail BEFORE allocating: `check_int32_offsets` is called ahead of the data
# buffer allocation at every site, so an overflowing column raises without
# first committing >2 GiB of RSS.
#
# Adaptive promotion to Int64 offsets is `should_promote_offsets`; the guard's
# only job is to convert a silent wrong answer into a named error.
# =============================================================================


comptime ARROW_INT32_OFFSET_MAX: Int = 2147483647
"""Largest byte offset representable in an Arrow 32-bit offsets buffer."""


comptime ARROW_INT64_OFFSET_MAX: Int = 9223372036854775807
"""Largest byte offset representable in an Arrow 64-bit offsets buffer.

⚠ THIS CEILING IS OF A DIFFERENT KIND FROM `ARROW_INT32_OFFSET_MAX`, AND THE
DIFFERENCE IS WHY THERE IS NO `check_int64_offsets` HELPER BESIDE THE INT32
ONE. The int32 ceiling is CROSSED IN PRODUCTION — 2 GiB of string data is one
large join result, which is the entire reason `large_string` exists. The int64
ceiling is ~9.2 exabytes, i.e. unreachable for any buffer
whose bytes are resident.

It is exported so a wide-offset kernel can state its ceiling in the
overflow-SAFE form (`a > ARROW_INT64_OFFSET_MAX - b`, never `a + b > MAX`)
instead of writing a comment claiming the check is unnecessary. A guard that
costs one compare and can never fire is still a guard; a comment is not.
"""


@always_inline
def int32_offsets_overflow(total_bytes: Int) -> Bool:
    """Does `total_bytes` exceed what an Arrow Int32 offsets buffer can address?

    Pure, allocation-free, branch-only. `offsets[N] == total_bytes` must fit in
    a signed 32-bit integer, so the ceiling is `INT32_MAX` inclusive.

    Args:
        total_bytes: Total data-buffer byte count the offsets must address.

    Returns:
        True if narrowing this total to Int32 would wrap.
    """
    return total_bytes > ARROW_INT32_OFFSET_MAX


@always_inline
def clamp_offset_promote_at(n: Int) -> Int:
    """The effective byte total above which a varlen producer PROMOTES to Int64.

    In production the trip point is `ARROW_INT32_OFFSET_MAX` and nothing else —
    the promotion fires exactly where the Int32 narrowing would have wrapped,
    and not one byte earlier. A caller may supply a LOWER trip point (the
    `promote_at` / `offset_promote_at` parameter of the promoting producers,
    carried on the engine configuration as `offset_promote_at`).

    ★ WHY THE TRIP POINT IS A PARAMETER AT ALL. The promoted arm is a SECOND
    set of offset-store, buffer-sizing and tag-stamping code, and reaching it
    at the real ceiling costs **2 GiB of gathered string payload**. A wide arm
    exercised only by a run that takes minutes and gigabytes of RSS is, for
    practical purposes, exercised by nobody: it cannot run as a unit test, so
    it cannot go red on a regression, so the first report of a defect in it is
    a wrong answer in front of a user. Lowering the trip point runs the SAME
    arms over a hundred bytes.

    ⚠ WHAT THE PARAMETER MOVES, AND WHAT IT MUST NEVER MOVE. It moves the
    THRESHOLD. It does not select a different code path, relax a check, or
    switch a kernel — a caller lowering it runs precisely the buffers, stores
    and tags that a 2 GiB production gather runs. If a future change makes it
    alter behaviour beyond the trip point, it has stopped being a test of the
    production path and must be deleted rather than fixed.

    The clamp FAILS CLOSED: a non-positive value, or one ABOVE the real
    ceiling, yields the production ceiling. An override that raised the trip
    point would re-arm the silent wrap this module exists to abolish.

    Args:
        n: The requested trip point in bytes.

    Returns:
        `n` if `0 < n <= ARROW_INT32_OFFSET_MAX`, else `ARROW_INT32_OFFSET_MAX`.
    """
    if n <= 0 or n > ARROW_INT32_OFFSET_MAX:
        return ARROW_INT32_OFFSET_MAX
    return n


@always_inline
def should_promote_offsets(
    total_bytes: Int, promote_at: Int = ARROW_INT32_OFFSET_MAX
) -> Bool:
    """Should a varlen producer emit Int64 offsets for this byte total?

    The promotion twin of `int32_offsets_overflow`, and the ONE predicate
    every promoting producer calls. Separate from `int32_offsets_overflow`
    because the two answer different questions: that one asks "would narrowing
    wrap" and is what the still-raising guard sites use; this one asks "should
    this producer widen", and only it honours a lowered trip point
    (`clamp_offset_promote_at`).

    Args:
        total_bytes: Total data-buffer byte count the offsets must address.
        promote_at: Trip point in bytes; clamped by `clamp_offset_promote_at`.
            Defaults to the production ceiling.

    Returns:
        True if the producer should emit a 64-bit offsets buffer.
    """
    return total_bytes > clamp_offset_promote_at(promote_at)


@always_inline
def wrap_to_int32(v: Int) -> Int:
    """Two's-complement narrowing of `v` to 32 bits, computed arithmetically.

    Used only to SHOW the caller the bogus value the silent narrowing would
    have produced. Computed with masking rather than `Int32(v)` so the message
    does not itself depend on the conversion semantics it is describing.

    Args:
        v: The 64-bit value that was about to be narrowed.

    Returns:
        The signed 32-bit value `v` would have become.
    """
    var m = v & 0xFFFFFFFF
    if m >= 0x80000000:
        m -= 0x100000000
    return m


def arrow_int32_offset_overflow(
    site: StaticString,
    imm column: String,
    total_bytes: Int,
    n_values: Int,
) -> Error:
    """Build the named `ArrowOffsetOverflow` error. COLD path only.

    Only ever invoked on the failing branch, so the String building here costs
    nothing in steady state.

    Args:
        site: Producer that detected the overflow (`"StringArray.from_strings"`).
        column: Column name if the producer knows one, else empty.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Returns:
        An `Error` naming the column, the byte count, the limit, and the
        wrapped value the silent narrowing would have produced.
    """
    return Error(
        _int32_offset_overflow_message(
            site, StaticString(""), column, total_bytes, n_values
        )
    )


def _int32_offset_overflow_message(
    site: StaticString,
    producer: StaticString,
    imm column: String,
    total_bytes: Int,
    n_values: Int,
) -> String:
    """THE ONE definition of the overflow message body. COLD path only.

    Both the plain and the producer-attributed builders route through here, so
    an edit to the wording cannot drift between the two spellings.

    Args:
        site: Constructor that detected the overflow.
        producer: Caller that asked for the column, or `""` if unattributed.
        column: Column name if the producer knows one, else empty.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Returns:
        The full message text.
    """
    var col_part: String
    if column.byte_length() == 0:
        col_part = String("<unnamed column>")
    else:
        col_part = String("column '") + column + String("'")
    var prod = String(producer)
    var prod_part: String
    if prod.byte_length() == 0:
        prod_part = String(
            " (producer UNATTRIBUTED: this call site passes no `producer=`"
            " identity, so this message can name only the constructor that"
            " DETECTED the overflow, which is shared by many callers. See"
            " offset_overflow.mojo's attribution section.)"
        )
    else:
        prod_part = String(" (produced by ") + prod + String(")")
    return (
        String("ArrowOffsetOverflow: ")
        + col_part
        + String(" at ")
        + String(site)
        + prod_part
        + String(" needs ")
        + String(total_bytes)
        + String(" data bytes for ")
        + String(n_values)
        + String(" values, which exceeds the Arrow 32-bit string/binary offset"
                 " limit of ")
        + String(ARROW_INT32_OFFSET_MAX)
        + String(" (offsets[N] must fit in Int32). Narrowing would silently"
                 " wrap to ")
        + String(wrap_to_int32(total_bytes))
        + String(", leaving every row past byte ")
        + String(ARROW_INT32_OFFSET_MAX)
        + String(" unaddressable while the row COUNT stayed correct. Use a"
                 " 64-bit-offset column (LARGE_STRING / LARGE_BINARY) or emit"
                 " this column in smaller batches.")
    )


@always_inline
def check_emittable_int32_offsets(
    site: StaticString,
    total_bytes: Int,
    n_values: Int,
    *,
    promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises:
    """Raise if a producer that can ONLY emit Int32 offsets must not proceed.

    ★ THE REFUSING TWIN OF `should_promote_offsets`, AND THE DIFFERENCE FROM
    `check_int32_offsets` IS THE `promote_at` TRIP POINT — NOT THE PRODUCTION
    BEHAVIOUR. Both trip at `ARROW_INT32_OFFSET_MAX` by default, because
    `clamp_offset_promote_at` CAPS the trip point at that value and can only
    ever lower it. That cap is what makes this substitution safe rather than
    merely convenient: `total > ARROW_INT32_OFFSET_MAX` IMPLIES
    `total > clamp_offset_promote_at(promote_at)`, so this predicate can fire
    EARLIER than the hard ceiling but can never fire LATER — it cannot miss a
    wrap `check_int32_offsets` would have caught.

    ⚠ WHY A TRIP-POINT-HONOURING VARIANT EXISTS FOR THE STREAMING CONCAT.
    Reaching this guard through `check_int32_offsets` costs a genuine 2 GiB of
    input, and the GREEN direction is cheap only because the guard fires before
    the copy. The RED direction is not: with the guard removed the kernel goes
    and does the 2 GiB concat — which is the silent wrong answer under test —
    and takes tens of minutes. A falsifier nobody can afford to run is not a
    falsifier, so the mutation legs drive this predicate with the trip point
    lowered to a hundred bytes and run in milliseconds, over the SAME guard,
    the SAME call site and the SAME error.

    Use this at a site that REFUSES at the ceiling. Use `check_int32_offsets`
    at a site whose trip point must be the hard ceiling and nothing else.

    Args:
        site: Producer performing the check.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.
        promote_at: Trip point in bytes; clamped by `clamp_offset_promote_at`.
            Defaults to the production ceiling.

    Raises:
        Error: named `ArrowOffsetOverflow`, when the total exceeds the
            (possibly lowered) trip point.
    """
    if not should_promote_offsets(total_bytes, promote_at):
        return
    var limit = clamp_offset_promote_at(promote_at)
    var tail: String
    if limit == ARROW_INT32_OFFSET_MAX:
        tail = String(
            ". Narrowing would silently wrap to "
        ) + String(wrap_to_int32(total_bytes)) + String(
            ", leaving every row past byte "
        ) + String(ARROW_INT32_OFFSET_MAX) + String(
            " unaddressable while the row COUNT stayed correct."
        )
    else:
        # The trip point is lowered. Say so IN the message: a reader who sees
        # this error in a log must not conclude that 2 GiB of data was involved.
        tail = String(
            ". THE TRIP POINT IS LOWERED (the `promote_at` parameter)"
            " from the real Arrow ceiling of "
        ) + String(ARROW_INT32_OFFSET_MAX) + String(
            " bytes; the production predicate is otherwise identical."
        )
    raise Error(
        String("ArrowOffsetOverflow: at ")
        + String(site)
        + String(" a column needs ")
        + String(total_bytes)
        + String(" data bytes for ")
        + String(n_values)
        + String(" values, which exceeds the ")
        + String(limit)
        + String(
            "-byte total this producer can address with a 32-bit offsets"
            " buffer"
        )
        + tail
        + String(
            " This producer emits 32-bit offsets only and cannot promote to"
            " LARGE_STRING / LARGE_BINARY; bring the column in smaller"
            " batches, or route it through a kernel that has a 64-bit-offset"
            " arm."
        )
    )


@always_inline
def check_int32_offsets(
    site: StaticString,
    imm column: String,
    total_bytes: Int,
    n_values: Int,
) raises:
    """Raise `ArrowOffsetOverflow` if `total_bytes` will not fit Int32 offsets.

    Call this once per column, AFTER the byte total is known and BEFORE the
    data buffer is allocated / the offsets are narrowed.

    Args:
        site: Producer performing the check.
        column: Column name if known, else empty.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Raises:
        Error: named `ArrowOffsetOverflow`, when the total exceeds INT32_MAX.
    """
    if int32_offsets_overflow(total_bytes):
        raise arrow_int32_offset_overflow(site, column, total_bytes, n_values)


@always_inline
def check_int32_offsets(
    site: StaticString,
    total_bytes: Int,
    n_values: Int,
) raises:
    """Column-name-less overload for producers that have no name in scope.

    Args:
        site: Producer performing the check.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Raises:
        Error: named `ArrowOffsetOverflow`, when the total exceeds INT32_MAX.
    """
    if int32_offsets_overflow(total_bytes):
        raise arrow_int32_offset_overflow(
            site, String(), total_bytes, n_values
        )


# =============================================================================
# PRODUCER ATTRIBUTION — the half that makes a refusal ACTIONABLE
# =============================================================================
#
# THE DEFECT THIS CLOSES. A full-scale refusal reported:
#
#   ArrowOffsetOverflow: <unnamed column> at StringArray.from_strings needs
#   3374058173 data bytes for 18342019 values ...
#
# and that message CANNOT BE ACTED ON. `StringArray.from_strings` has many
# callers; the message names the CONSTRUCTOR, which is
# the one participant that does not know why it was called. Worse, it is
# actively MISLEADING: `from_strings_with_validity` DELEGATES to `from_strings`
# on its all-valid fast path, so a producer that called the NULLABLE
# constructor is reported as having called the non-nullable one — and grepping
# for the reported site therefore cannot find the producer at all. The raise is
# often CAUGHT and re-reported as a one-line result, so there is no stack
# trace to fall back on, and counters that WOULD discriminate only print on a
# successful run, i.e. never on the run that refuses. The message is the only
# evidence there is.
#
# THE FIX IS A SECOND, OPTIONAL IDENTITY that travels with the call: `site`
# stays what it has always been (the CONSTRUCTOR that detected the overflow),
# and `producer` names the CALLER that asked for the column. Separate fields
# because they answer different questions; a single string would force one of
# them out.
#
# WHY A DEFAULTED `StaticString` AND NOT A THREAD-LOCAL BREADCRUMB. A "current
# producer" global set before each drain would attribute the WRONG producer
# under the parallel drains this tree runs — and an attribution that is wrong
# under concurrency is worse than none, because it sends the reader somewhere
# confidently. A defaulted parameter is resolved at the CALL, cannot race,
# costs nothing at run time (a `StaticString` is a pointer + length in the
# constant pool), and leaves every unconverted caller reporting exactly what it
# reports today — plus a sentence saying it is unattributed, so that a partial
# message is not mistaken for a complete diagnosis.
# =============================================================================


def arrow_int32_offset_overflow_attributed(
    site: StaticString,
    producer: StaticString,
    imm column: String,
    total_bytes: Int,
    n_values: Int,
) -> Error:
    """`arrow_int32_offset_overflow`, naming the PRODUCER as well as the site.

    Args:
        site: Constructor that detected the overflow.
        producer: Caller that asked for the column, or `""` if unattributed.
        column: Column name if the producer knows one, else empty.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Returns:
        The `ArrowOffsetOverflow` error, with the producer clause directly
        after the site.
    """
    return Error(
        _int32_offset_overflow_message(
            site, producer, column, total_bytes, n_values
        )
    )


@always_inline
def check_int32_offsets_attributed(
    site: StaticString,
    producer: StaticString,
    total_bytes: Int,
    n_values: Int,
) raises:
    """`check_int32_offsets`, plus the producer's identity in the message.

    Args:
        site: Constructor performing the check.
        producer: Caller that asked for the column, or `""` if unattributed.
        total_bytes: Data bytes the column needs to address.
        n_values: Number of values (rows) in the column.

    Raises:
        Error: named `ArrowOffsetOverflow`, when the total exceeds INT32_MAX.
    """
    if int32_offsets_overflow(total_bytes):
        raise arrow_int32_offset_overflow_attributed(
            site, producer, String(), total_bytes, n_values
        )
