# =============================================================================
# join_payload_inline -- the WIDTH GATE and the FIRE witness for the
# PAYLOAD-INLINE chain-entry layout (2026-09-01)
# =============================================================================
#
# WHAT THE LEVER IS. The shipped chain entry is `key + next`, 16 B fused
# (`join.mojo`'s `key_next`), and `build_indices` is elided so `chain_idx` IS
# the build row. The build PAYLOAD is therefore NOT in the entry, so every
# output row fetches it by index out of the build-side column -- a second
# random touch of a second multi-hundred-megabyte array, on a row the probe's
# chain walk has ALREADY brought into L1.
#
# This lever widens the entry to 32 B -- `[key | next | payload | pad]` -- so
# the probe's EXISTING chain touch yields the payload and the gather is deleted
# outright. DuckDB does the same thing (`tuple_data_layout.cpp:52-100`, one row
# of `[flags | key | build_val | hash/next]`): the difference between the two
# engines here is LAYOUT AT EQUAL DIRECTORY SIZE, not directory size.
#
# ★ MEASURED, BEFORE ANY OF THIS WAS WRITTEN. Toggling the join-key CSE on hc4
# changes ONLY how many build columns are randomly gathered (1 -> 2), holding
# query, row count, output width and assembly arm fixed. On one host, 44 workers,
# ONE binary:
#
#     CSE OFF (2 gathered build cols)   72.95 GiB/rep   1.455 s/rep
#     CSE ON  (1 gathered build col)    61.76 GiB/rep   1.225 s/rep
#     PER GATHERED COLUMN               11.19 GiB       230 ms  (-15.8%)
#
# The pre-registered bands were ~8.6 GiB (the random-gather mechanism holds) vs
# ~2.6 GiB (the gather is LLC-resident and cheap). 11.19 is ABOVE the upper
# band, so the mechanism is confirmed and each gathered column costs ~91 B/row.
#
# =============================================================================
# ⛔⛔ WHY THERE IS A HARD WIDTH GATE, AND WHY IT IS NOT A PREFERENCE
# =============================================================================
#
# Widening the entry is not free: it multiplies the size of the array the probe
# walks RANDOMLY, and at most widths it makes a chain record STRADDLE two cache
# lines. The calibrated model
# (an offline model) -- which
# reproduces hc4's 100,009,017 output rows and 26.71% mismatching chain visits
# bit-for-bit -- prices every candidate width over hc4's real 136,456,286 chain
# visits:
#
#     W    entry lines  vs 16B   straddles (% of visits)   NET GB/rep
#     16    136,456,278  1.0000        0.0000             -   (shipped)
#     24    170,575,640  1.2500        0.2500            -3.82
#     32    136,456,278  1.0000        0.0000            -5.80  <-- WINS
#     40    204,673,807  1.4999        0.4999            -1.23
#     48    204,685,193  1.5000        0.5000            -1.03
#     56    238,793,180  1.7500        0.7500            +1.35   NET LOSS
#     64    136,456,286  1.0000        0.0000            -5.00
#     72    272,912,564  2.0000        1.0000            +3.93   NET LOSS
#
# Two things that table says, and both are load-bearing:
#
#   1. **AT 32 B THE PROBE PAYS NOTHING FOR THE EXTRA 16 B.** The entry-line
#      count is IDENTICAL to the shipped 16 B layout. Chain entries within one
#      probe walk are already effectively random -- only 8 line touches out of
#      136.5 M were ever shared -- so halving the entries-per-line changes
#      nothing, while the straddle term is zero because 32 divides 64.
#
#   2. **AT 72 B THE LEVER IS A NET LOSS.** Every one of the 136.5 M chain
#      visits straddles, so the walk pays 2 lines to delete 100 M gathers. Since
#      the join-key CSE already removes the key column, `k` is
#      `(build output cols - 1)`, and a TPC-H `SELECT *` join is k~8 -- 80 B.
#      This lever is therefore MOSTLY INAPPLICABLE, and a gate that merely
#      preferred narrow entries would regress those cells.
#
# ⚠ The straddle story is really "POWER-OF-TWO WIDTH", not "<= 32 B": W=64 is
# also 1.0000x entry lines. The gate is still at 32 B, for a reason the
# line-touch model cannot see -- W=64 doubles the entry array to 1.53 GB of
# randomly-touched footprint against 763 MB -- and because it nets LESS anyway
# (-5.00 vs -5.80). Narrow is both simpler and strictly better here.
#
# ⚠ hc4 has exactly ONE gathered build column (the CSE removed the other), so
# capacity beyond k=1 buys no second gather to delete and is pure cost. That is
# why `k == 1` is part of the gate and not just the width.
#
# ⚠ THE MODEL UNDER-COUNTS MAGNITUDE BY ~1.9x. It prices one gathered column at
# 6.40 GB against the 12.01 GB measured on that host -- the same shortfall
# recorded for the deferral traffic rule. It is a UNIFORM under-count of random
# line touches, so it preserves RANKING and makes every figure above
# conservative. Do not quote a model GB as a predicted wall.
#
# =============================================================================
# ⛔ THE SHAPES THIS REFUSES, AND WHY EACH ONE IS NOT A TUNING DECISION
# =============================================================================
#
#   * **STRING / BINARY / LARGE_STRING payload.** A fixed-stride entry cannot
#     hold one, and inlining an (offset, len) pair still leaves the CHARACTER
#     DATA behind a random fetch -- the lever would move 16 B into the entry and
#     delete nothing.
#   * **DICTIONARY payload.** Inlining the CODE still requires resolving the
#     dictionary per output row, so again nothing is deleted. This is the same
#     shape `admits_deferral`'s `probe_bytes < 0` refusal exists for: parquet
#     picks its encoding PER ROW GROUP, so one dictionary-encoded morsel beside
#     plain neighbours is the reachable production shape, and treating its codes
#     as values is a silent wrong answer with a correct row count.
#   * **NULLABLE payload.** Possible, but it costs a validity bit in the entry
#     plus a bitmap rebuild on the emit side. Gated out for v1 rather than
#     half-implemented: an inlined value with no inlined validity is exactly the
#     "wrong answer, right row count" failure above.
#
# =============================================================================
# THE OBSERVABLE, AND WHY IT IS NOT OPTIONAL
# =============================================================================
#
# ⛔ THIS LEVER IS VALUE-INVARIANT BY CONSTRUCTION, SO A BYTE ORACLE CANNOT TELL
# WHICH ARM RAN. That is the entire claim -- and it is also exactly how
# an earlier change shipped a join lever that fired on **0 of 84 corpus cells** with
# nothing going red. So the arm is counted, both dispositions, and the counters
# (not the printed line) are what the tests assert. Same reason, same idiom, as
# `join_layout_counter` and `join_probe_phase_split`'s FIRE witness.
#
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.io import FileDescriptor
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_arrow.arrow_types import ArrowType
from .join_key_cse import JoinKeyAliasMap


# -----------------------------------------------------------------------------
# Layout constants
# -----------------------------------------------------------------------------

# Words per chain entry under the SHIPPED fused layout: [key, next].
# fd 2. `plan_exec`'s stdout is its RESULT STREAM -- a diagnostic written
# there is not a log line, it is a CORRUPTED ANSWER. Same spelling and same
# reason as `komira_engine_operators/join_layout_counter.mojo:67`, which is
# this marker family's other three members.
comptime _PAY_STDERR: FileDescriptor = FileDescriptor(2)

comptime JOIN_KN_WORDS: Int = 2

# Words per chain entry under PAYLOAD-INLINE: [key, next, payload, pad].
#
# ⚠ THE PAD WORD IS THE LEVER, NOT WASTE. A 24 B entry holds exactly the same
# information and is 25% WORSE (see the table above): 2 of every 8 records
# straddle a 64 B line, so a quarter of 136.5 M chain visits become two line
# touches. The pad buys the straddle term back to zero for free, because at
# 32 B the probe touches the SAME number of lines as it does at 16 B.
#
# It also keeps `test_join_fused_record_one_line` green with a constant change
# rather than an argument: that test asserts `base % 16 == 0` and
# `straddling == 0`, and 32 satisfies both where 24 satisfies neither.
comptime JOIN_KN_WORDS_PAY: Int = 4

# Entry byte width above which the lever REFUSES. See the model table.
comptime JOIN_PAY_MAX_ENTRY_BYTES: Int = 32

# Payload columns the entry may carry. Exactly one; see the header.
comptime JOIN_PAY_MAX_COLS: Int = 1


# -----------------------------------------------------------------------------
# Runtime configuration -- set ONCE per process from a flag, never per call
# -----------------------------------------------------------------------------
#
# ⛔ A FLAG, NOT AN ENVIRONMENT VARIABLE. `join_payload_inline_configure` sets
# it, once per process at startup; nothing in this module reads
# the environment. The arming decision is made per BUILD, and this module's gate
# is also consulted from the probe side's accounting, so the setting lives in a
# process-global and every read is one relaxed load.
#
#   0 = not configured (reads as OFF, the default),  -1 = OFF,  1 = ON


def _init_pay_i64() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _PAY_CFG = _Global["komira_join_payload_inline_cfg", _init_pay_i64]
comptime _PAY_FIRED = _Global[
    "komira_join_payload_inline_fired", _init_pay_i64
]
comptime _PAY_DECLINED = _Global[
    "komira_join_payload_inline_declined", _init_pay_i64
]
comptime _PAY_PROBED = _Global[
    "komira_join_payload_inline_probed", _init_pay_i64
]
comptime _PAY_SERVED = _Global[
    "komira_join_payload_inline_served", _init_pay_i64
]


def join_payload_inline_enabled() raises -> Bool:
    """Is the payload-inline flag on? DEFAULT-OFF.

    Set once per process by `join_payload_inline_configure`; an unconfigured
    process reads OFF. See the block comment above.
    """
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets
    # KGEN-runtime static storage (process lifetime); the wildcard origin is the
    # stdlib API's own return type and is confined to this function.
    var gp = _PAY_CFG.get_or_create_ptr()
    var cur = Int(gp[][].load())
    if cur != 0:
        return cur > 0
    return False


def join_payload_inline_configure(on: Bool) raises:
    """Set the payload-inline flag for this process. DEFAULT-OFF.

    Meant to be called once at startup, before any join builds.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _PAY_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if on else -1))


def join_payload_inline_reset_config() raises:
    """Return the payload-inline flag to its default (OFF, unconfigured).

    TEST-ONLY. Production sets the flag once at startup; a test that drives
    the gate from BOTH sides has to be able to move it between cases in ONE
    process.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _PAY_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


# -----------------------------------------------------------------------------
# The width gate
# -----------------------------------------------------------------------------


def join_payload_entry_bytes(pay_inline: Bool) -> Int:
    """Bytes of ONE chain entry under the layout `pay_inline` selects.

    ⚠ THE TWO ACCOUNTING SITES THAT PRICE THE INDEX MUST READ THIS AND NOT A
    LITERAL 16. `join_phase_split_index_bytes` and `admits_deferral` both
    hard-coded the shipped width, and hc4 sits on the knife edge of the second
    one -- a stale 16 there silently moves an UNRELATED lever's decision.
    """
    if pay_inline:
        return JOIN_KN_WORDS_PAY * 8
    return JOIN_KN_WORDS * 8


def join_payload_type_admits(t: ArrowType) -> Bool:
    """May a column of this type ride in the entry's 8-byte payload word?

    ⛔ AN EXPLICIT ALLOW-LIST, NOT A WIDTH TEST. `element_size(t) == 8` is the
    tempting spelling and it is wrong twice over: DICTIONARY reports the width
    of its CODES (so the check would admit a column whose real bytes are still
    behind a random dictionary lookup -- the lever would delete nothing and
    could emit codes as values), and DECIMAL128 is 16. Only types whose ENTIRE
    value is one 8-byte word, copied bit-for-bit, are listed. Everything else --
    including any type added after this was written -- is REFUSED by default,
    which is the direction that cannot produce a wrong answer.

    The payload travels as a raw 64-bit word from build to output, so the
    FLOAT64 and TIMESTAMP members need no conversion: nothing on the path ever
    interprets it, and the output column is rebuilt with the SOURCE column's own
    `arrow_type`.
    """
    return (
        t == ArrowType.INT64
        or t == ArrowType.UINT64
        or t == ArrowType.FLOAT64
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
    )


def join_payload_inline_admits(
    num_pay_cols: Int,
    pay_type: ArrowType,
    pay_nullable: Bool,
) raises -> Bool:
    """May the build inline its payload into the chain entry?

    Five conditions. Each is a place the lever is known to be WORTHLESS or
    UNSAFE, not merely unhelpful -- see the header for the evidence behind each.

      1. The payload-inline flag is on. DEFAULT-OFF.
      2. EXACTLY ONE payload column. `k = build output cols - 1`; k=0 has
         nothing to inline, and k>=2 buys no extra deleted gather on the shape
         that motivated the lever while paying the full width.
      3. THE PAYLOAD TYPE IS ON THE ALLOW-LIST. See `join_payload_type_admits`:
         STRING / BINARY / LARGE_STRING / DICTIONARY all leave the real bytes
         behind a random fetch, so inlining them deletes nothing and (for
         DICTIONARY) risks emitting codes as values.
      4. THE PAYLOAD IS NOT NULLABLE. An inlined value with no inlined validity
         is a wrong answer with a correct row count.
      5. THE RESULTING ENTRY IS <= `JOIN_PAY_MAX_ENTRY_BYTES`. The HARD width
         gate; above it the straddle term turns the lever into a net loss.

    Every refusal is counted, so "the gate declined" is an assertable fact and
    not the absence of one.
    """
    if not join_payload_inline_enabled():
        _record_declined()
        return False
    if num_pay_cols != JOIN_PAY_MAX_COLS:
        _record_declined()
        return False
    if not join_payload_type_admits(pay_type):
        _record_declined()
        return False
    if pay_nullable:
        _record_declined()
        return False
    if join_payload_entry_bytes(True) > JOIN_PAY_MAX_ENTRY_BYTES:
        _record_declined()  # cov: unreachable the shipped entry is exactly 32 B
        return False  # cov: unreachable the shipped entry is exactly 32 B
    return True


# -----------------------------------------------------------------------------
# FIRE / DECLINE witnesses
# -----------------------------------------------------------------------------


def _record_declined() raises:
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _PAY_DECLINED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_payload_inline_record_build(rows: Int, pay_build_col: Int) raises:
    """Record -- and announce -- one build that produced the WIDE entry.

    Prints `[JOIN_CHAIN_LAYOUT] payload=1 ...` **ON FD 2**, the same marker
    family `join_layout_record_build` uses, so one grep finds every chain-entry
    lever's disposition.

    ⛔⛔ IT WAS ON FD 1 UNTIL 2026-09-14, AND THE DOCSTRING THAT DEFENDED THAT
    IS FALSIFIED. It read: "It prints ONLY on the non-default arm: the control
    arm's stdout has to stay byte-identical or the A/B harness is comparing two
    different amounts of I/O." Both halves are wrong as a defence:

      * `plan_exec`'s STDOUT IS ITS ROW STREAM. A line there is not extra I/O
        charged to one arm, it is a CORRUPTED ANSWER -- measured on this exact
        marker family: `[JOIN_CHAIN_LAYOUT]` from `join_layout_record_build`
        landed in front of the header and DuckDB scored SQ20/SQ21/SQ22 as
        `HEADER differs`, while a join-rows test died in 14 of 28
        tests on `int('[JOIN_PROBE_LAYOUT] ...')`.
      * "only on the non-default arm" is a statement about TODAY'S default, not
        about the code. Its two sibling levers (`nobi`, `keynext`) both SHIPPED
        as True, and the day this one does the same the line is on every user's
        row stream. The other three members were moved to fd 2 rather than left
        to that argument; this one is the fourth.

    The FIRE-arm-only behaviour is unchanged -- fd 2 is where it goes, not
    whether it goes -- so an A/B harness grepping for the witness still finds
    it, on the channel diagnostics belong on.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _PAY_FIRED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))
    print(
        "[JOIN_CHAIN_LAYOUT] payload=1 entry_bytes=",
        join_payload_entry_bytes(True),
        " rows=",
        rows,
        " build_col=",
        pay_build_col,
        # What the arm allocated, and what it deletes downstream, in bytes --
        # the marker states the SIZE of the change and not merely that it
        # happened.
        " keynext_bytes=",
        rows * join_payload_entry_bytes(True),
        " keynext_bytes_shipped=",
        rows * join_payload_entry_bytes(False),
        file=_PAY_STDERR,
    )


def join_payload_inline_record_probe() raises:
    """Record the first PROBE that actually entered a payload-carrying kernel.

    ⛔ A BUILT INDEX NOTHING PROBES IS NOT A LEVER. `join_layout_counter`'s
    header records the same distinction and the same reason: the build-side
    counter proves the layout was CONSTRUCTED, and only this one proves a probe
    entered the specialised loop. Counted every time (it is off the per-row
    path -- once per chunk call, not once per row).
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _PAY_PROBED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_payload_inline_fired_count() raises -> Int:
    """Builds that produced the payload-inline layout, process-wide."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_PAY_FIRED.get_or_create_ptr()[][].load())


def join_payload_inline_declined_count() raises -> Int:
    """Times the gate REFUSED, process-wide."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_PAY_DECLINED.get_or_create_ptr()[][].load())


def join_payload_inline_probed_count() raises -> Int:
    """Probe-kernel entries that carried an inlined payload, process-wide."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_PAY_PROBED.get_or_create_ptr()[][].load())


def join_payload_inline_note_served(columns: Int) raises:
    """Record output columns an ASSEMBLE emitted from the INLINED payload.

    ⛔ THIS IS THE COUNTER THAT PROVES THE GATHER WAS DELETED, and it is a
    different fact from either of the two above. `..._fired_count` says the wide
    index was BUILT; `..._probed_count` says a probe kernel ENTERED carrying the
    payload. Neither implies the assemble actually SERVED a column from it -- a
    window that did not cover the payload list, or a CSE that aliased the same
    column, both fall back to the gather with everything green. Without this
    counter "the lever fired" and "the lever saved anything" are indistinguish-
    able, which is the exact failure the module header names.

    ⚠ BATCHED PER ASSEMBLE, NOT PER COLUMN -- the same cost argument as
    `join_key_cse_note_shares`, and zero-guarded by its caller so an assemble
    that serves nothing touches no atomic at all.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _PAY_SERVED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(columns))


def join_payload_inline_served_count() raises -> Int:
    """Output columns served from an inlined payload, process-wide."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_PAY_SERVED.get_or_create_ptr()[][].load())


def reset_join_payload_inline_counters() raises:
    """TEST-ONLY: zero all four witnesses."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _PAY_FIRED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PAY_DECLINED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PAY_PROBED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _PAY_SERVED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


# =============================================================================
# PAYLOAD SUBSTITUTION -- the pay-subst flag (2026-09-02)
# =============================================================================
#
# ⛔ WHAT THIS FIXES, AND WHY IT IS A CORRECTION AND NOT A SECOND LEVER.
# The payload-inline flag above deletes the build-side GATHER, and the
# phase profile says it does exactly that: on hc4 the gather phase goes 95.5 ms
# -> 0.0 ms. And yet the wall moved +162.5 ms, because the deferred record was
# taught to hold the payload as a THIRD retained list ALONGSIDE the build match
# index rather than INSTEAD OF it -- and once the payload is in hand the build
# index has no reader left. The lever paid for a list it had just made dead.
#
#     per RETAINED match, bytes the probe loop writes
#       shipped default          probe_idx 8 + build_idx 8            = 16
#       PAYLOAD_INLINE (today)   probe_idx 8 + build_idx 8 + pay 8    = 24
#       PAYLOAD_INLINE + SUBST   probe_idx 8 +               pay 8    = 16
#
# ⭐ THAT LAST ROW IS ALSO THE MEASUREMENT DESIGN, NOT ONLY THE SAVING. The
# substituting arm writes the SAME bytes per match as the shipped default, so
# `probe_phase(SUBST) - probe_phase(OFF)` contains NO retention term and is
# attributable to the 32-byte chain entry alone. That is what separates the two
# pre-registered readings of the +58.5 ms the probe phase moved under
# PAYLOAD_INLINE (entry width, which SUBST cannot recover, vs retention
# pressure, which it recovers entirely). `test_pay_subst_probe_retention_equals_
# the_default_arm` asserts the equality, so the attribution is a checked
# invariant rather than a claim about the code.
#
# ⛔ WHAT MAKES IT SOUND, AND IT IS NOT "the CSE will be on". The deferred
# assembly reads the build match index for exactly one thing: gathering the
# build-side OUTPUT columns. Under this lever's own arming gate the build side
# has EXACTLY TWO columns -- the join key and the one inlined payload -- so a
# record may drop its build index only when BOTH are served without it:
#
#   * the PAYLOAD column, from `DeferredJoinChunk.build_pay` (already shipped);
#   * every OTHER build column, from the JOIN-KEY CSE alias, which names a
#     PROBE column holding the same value on every emitted row.
#
# The second condition is decided PER MORSEL (`JoinProbeOp._cse_admits_morsel`)
# while the assembly's whole-column share needs EVERY record to agree, so
# "this record may elide" does NOT imply "the assembly will share the column".
# A record therefore carries its own alias vector, and the assembly gathers an
# elided record's build column FROM THE PROBE SIDE, by that record's own probe
# index, whenever the whole-column share does not apply. That fallback is what
# makes the elision unconditional-safe instead of dependent on a global fact a
# worker cannot see; it is also strictly cheaper than what it replaces, since a
# probe-side gather is near-sequential where the build-side one is random.
#
# ⛔ A FLAG, DEFAULT-OFF, set once -- same `_Global` idiom, and the same
# reason, as `join_payload_inline_enabled` above.

comptime _SUBST_CFG = _Global["komira_join_pay_subst_cfg", _init_pay_i64]
comptime _SUBST_ELIDED = _Global["komira_join_pay_subst_elided", _init_pay_i64]
comptime _SUBST_KEPT = _Global["komira_join_pay_subst_kept", _init_pay_i64]
comptime _SUBST_FALLBACK = _Global[
    "komira_join_pay_subst_fallback", _init_pay_i64
]


def join_pay_subst_enabled() raises -> Bool:
    """Is the pay-subst flag on? DEFAULT-OFF.

    ⚠ IT IS A SEPARATE FLAG FROM THE PAYLOAD-INLINE FLAG ON PURPOSE. The
    incumbent lever stays exactly as it shipped so the additive form remains
    A/B-able against this one; this gate is INERT unless payload-inline armed
    the index, because there is no payload to substitute with otherwise.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _SUBST_CFG.get_or_create_ptr()
    var cur = Int(gp[][].load())
    if cur != 0:
        return cur > 0
    return False


def join_pay_subst_configure(on: Bool) raises:
    """Set the pay-subst flag for this process. DEFAULT-OFF. See
    `join_payload_inline_configure`."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _SUBST_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if on else -1))


def join_pay_subst_reset_config() raises:
    """TEST-ONLY: return the pay-subst flag to its default (OFF, unconfigured).
    See `join_payload_inline_reset_config`."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _SUBST_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def join_pay_subst_note_elided() raises:
    """One deferred record that DROPPED its build match index."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _SUBST_ELIDED.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_pay_subst_note_kept() raises:
    """One deferred record that probed a payload-inline index and KEPT its
    build match index anyway.

    ⛔ THIS IS THE COUNTER THAT MAKES A ZERO READABLE. `elided=0` alone cannot
    separate "the gate is off", "the index was never payload-inline" and "the
    gate is on, the index is wide, and every morsel was refused by the CSE
    condition" -- three states with three different next steps. Only records
    whose index actually carried a payload reach either counter, so
    `elided + kept` is the population the lever could ever have acted on.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _SUBST_KEPT.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_pay_subst_note_fallback() raises:
    """One assembly slice served by the PER-RECORD probe-side alias gather --
    i.e. a record elided its build index and the whole-column CSE share did not
    apply, so the build column came off the probe side instead.

    ⚠ A NON-ZERO HERE IS NOT A DEFECT; it is the safety path doing its job, and
    it is the only thing that distinguishes "the fallback exists" from "the
    fallback has never once executed", which is what a code-reading review
    cannot tell apart.
    """
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    var gp = _SUBST_FALLBACK.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_pay_subst_elided_count() raises -> Int:
    """Deferred records that dropped the build match index, process-wide."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_SUBST_ELIDED.get_or_create_ptr()[][].load())


def join_pay_subst_kept_count() raises -> Int:
    """Payload-carrying deferred records that kept the build match index."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_SUBST_KEPT.get_or_create_ptr()[][].load())


def join_pay_subst_fallback_count() raises -> Int:
    """Assembly slices served by the per-record probe-side alias gather."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    return Int(_SUBST_FALLBACK.get_or_create_ptr()[][].load())


def reset_join_pay_subst_counters() raises:
    """TEST-ONLY: zero the three witnesses."""
    # SAFETY: FFI carve-out (see `join_payload_inline_enabled`).
    _SUBST_ELIDED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _SUBST_KEPT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _SUBST_FALLBACK.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def join_pay_subst_alias(
    pay_col: Int,
    build_ncols: Int,
    probe_ncols: Int,
    imm cse_map: JoinKeyAliasMap,
    mut out_alias: List[Int32],
) raises -> Bool:
    """May a deferred record DROP its build match index? Fills `out_alias`.

    ⛔ THE QUESTION IS "IS THE INDEX DEAD", NOT "IS THE LEVER ON". The deferred
    assembly reads the build match index for exactly one purpose: gathering
    build-side output columns. So the index is dead iff every one of them has
    another source, and there are exactly two:

      * the INLINED PAYLOAD, for build column `pay_col`;
      * the JOIN-KEY CSE alias, for every OTHER build column -- a PROBE column
        proved to hold the same value on every row this morsel emits.

    The caller establishes the second source's per-morsel precondition
    (`JoinProbeOp._cse_admits_morsel`); what is added here is the QUANTIFIER --
    the map must cover EVERY build column, not merely the key -- and the ALIAS
    VECTOR, which the record carries because the assembly's whole-column share
    is a global fact no single worker can observe.

    ⚠ AN ALIAS MUST LAND INSIDE THE PROBE BATCH. `alias_of` is total and returns
    a probe column index; a value at or above `probe_ncols` would name a column
    the assemble's builder has not emitted, and that frame's own
    `alias_idx < builder.num_columns()` guard would then fall back to the
    GATHER -- with no index to gather by. Refusing here is what keeps that
    fallback reachable only where it is safe.

    ⚠ EVERY REFUSAL LEAVES `out_alias` EMPTY, at every exit. A half-filled
    vector on a refused morsel is a shape `DeferredJoinChunk.deferred_chunk`
    would then have to distrust; emptiness plus the flag is ONE statement.

    ⛔ `pay_col < 0` REFUSES rather than falling through to "every build column
    is aliased". A record with no payload has nothing substituting for the
    index, so eliding it would be the additive lever's bug with the sign
    flipped -- and a build side whose columns are ALL CSE-aliased is a shape the
    payload-inline gate refuses anyway (`k == 1`).

    Args:
        pay_col: the BUILD column the inlined payload serves, or -1.
        build_ncols: columns on the build side.
        probe_ncols: columns in this probe morsel.
        cse_map: the JOIN-KEY CSE alias map, already proved for this morsel.
        out_alias: filled with `build_ncols` entries on True (`-1` at
            `pay_col`), CLEARED on False.

    Returns:
        True iff the build match index may be dropped for this morsel.
    """
    out_alias.clear()
    if pay_col < 0 or pay_col >= build_ncols:
        return False
    if probe_ncols <= 0:
        return False
    if build_ncols <= 0:
        return False  # cov: unreachable the pay_col refusal above already requires build_ncols >= 1
    # The map is built per BUILD column; one shorter than the build batch
    # cannot answer for the columns past its end, and `alias_of` reports those
    # as -1 (= gather) rather than raising -- so the LENGTH is checked here and
    # not inferred from the per-column loop below.
    if len(cse_map) < build_ncols:
        return False
    for c in range(build_ncols):
        if c == pay_col:
            out_alias.append(Int32(-1))
            continue
        var a = cse_map.alias_of(c)
        if a < 0 or a >= probe_ncols:
            out_alias.clear()
            return False
        out_alias.append(Int32(a))
    return True
