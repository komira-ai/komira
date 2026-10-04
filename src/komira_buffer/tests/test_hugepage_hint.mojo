# =============================================================================
# test_hugepage_hint.mojo — large-allocation madvise(2) hint guard
# =============================================================================
#
# Guards `komira_buffer.hugepage_span` + the `madvise` hook in
# `komira_buffer.owned_aligned_buffer`.
#
# # What each oracle can actually catch (these are NOT tautologies)
#
#   [b] SPAN CONTRACT — sweeps adversarial (base_addr, size) pairs and asserts
#       containment / alignment / whole-pages / maximality. Swapping the
#       round-UP on `start` for a round-DOWN (the natural off-by-one) makes the
#       CONTAINMENT assert fire immediately: the span would begin BEFORE the
#       allocation. Verified RED by deliberate break, see below.
#   [e] SYSCALL RC — asserts the advice path actually executes and the kernel
#       accepts it, and that capacity / length / alignment are untouched.
#       ⚠ MEASURED LIMIT OF THIS ORACLE: rc does NOT detect an overshoot.
#       `madvise` only returns ENOMEM when the range leaves the MAPPING, and
#       tcmalloc serves our buffers out of one large arena, so a span running
#       2 MiB past the buffer still lands on mapped memory and returns 0. This
#       was verified empirically (see the deliberate-break log below) — do not
#       strengthen this docstring back into a containment claim.
#   [i] RUNTIME CONTAINMENT — this is the oracle that covers overshoot. It
#       asserts CONTAINMENT for the span computed from the buffer's REAL
#       tcmalloc address, which is what [e] cannot do.
#   [f][g] BYTE ORACLE — fills the buffer with a position-dependent pattern,
#       applies the advice, and re-verifies EVERY byte. `MADV_POPULATE_WRITE`
#       actually walks and populates every PTE in the range; the readback pins
#       the man-page guarantee that it does not modify contents.
#
# # DELIBERATE-BREAK VERIFICATION (an oracle must be able to fail in the
# # direction it guards). These breaks were run:
#
#   BREAK 1 — `hugepage_span`'s `start` round-UP inverted to a round-DOWN
#   (`(base_addr // HUGEPAGE_BYTES) * HUGEPAGE_BYTES`). Result: [b] went RED —
#   `AssertionError: span.offset < 0 (starts before the allocation) at
#   base=2097153`. Reverted; suite re-run green.
#
#   BREAK 2 — the advised LENGTH inflated by one hugepage in
#   `_apply_memory_hint` (`UInt64(span.length + 2*1024*1024)`), i.e. a
#   deliberate overshoot past the end of the buffer. Result: the suite stayed
#   GREEN. That is what proved the [e] rc assertion is NOT a containment
#   oracle, and is why [i] and the `debug_assert` in `_apply_memory_hint`
#   exist. Reverted.
#
#   BREAK 4 — [l], the `auto` decision table. `resolve_auto_mode` widened to
#   `enabled == MADVISE or enabled == ALWAYS -> ADVICE_HUGEPAGE`, i.e. the
#   plausible "the host supports THP, so use it" reading. Result: [l] went RED
#   — `AssertionError: enabled=[always] must REFUSE — advising there is a
#   pessimisation`. Reverted; suite re-run green.
#
#   BREAK 5 — [m], the probe-once freeze. `_frozen_thp_snapshot` changed to
#   call `_probe_thp_policy_uncached()` directly instead of reading the
#   `_Global`. Result: [m] went RED — `AssertionError: the host THP probe must
#   run exactly once per process, not per call`. This is the proof that the
#   counter is a real falsifier for the freeze and not a tautology. Reverted.
#
#   BREAK 6 — [j], the fail-closed arm. `parse_thp_enabled`'s fallthrough
#   changed from `THP_ENABLED_UNKNOWN` to `THP_ENABLED_MADVISE`, i.e. an
#   unreadable or unrecognised sysfs file falls OPEN into "capable". Result:
#   [j] went RED — `AssertionError: a MISSING/unreadable file reads as '' and
#   must be UNKNOWN, not a policy`. Reverted; suite re-run green.
#
#   BREAK 3 — isolating [i]: `memory_hint_span` fed `self._capacity +
#   2*1024*1024` so ONLY the runtime path overshoots while the pure function
#   stays correct. Result: [a]-[h] all PASSED and [i] went RED —
#   `AssertionError: advised span runs past the allocation: offset=0
#   length=10485760 capacity=8388608`. This is the proof that [i] is an
#   independent containment oracle and not shadowed by [b]. Reverted; suite
#   re-run green.
#
# # ⚠ THIS TEST DOES NOT PROVE THE HINT HELPS
#
# It proves the hint is SAFE and CONTENT-NEUTRAL. Whether it moves wall time
# depends on kernel THP policy. A process (or an ancestor) that sets
# `PR_SET_THP_DISABLE` makes `MADV_HUGEPAGE` a strict no-op for itself and
# every child; a host whose THP policy is `enabled=[madvise]` with the
# process flag clear resolves `auto` to ADVICE_HUGEPAGE and genuinely
# exercises the advice path. The oracles here are written to be
# host-INDEPENDENT precisely because test hosts disagree about this. See
# `hugepage_span.mojo`'s header.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_buffer.hugepage_span import (
    ADVICE_HUGEPAGE,
    ADVICE_OFF,
    ADVICE_POPULATE,
    HUGEPAGE_BYTES,
    HUGEPAGE_MIN_ALLOC_BYTES,
    HugepageSpan,
    hugepage_span,
    parse_memory_advice,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_host.thp_policy import (
    THP_DEFRAG_ALWAYS,
    THP_DEFRAG_DEFER,
    THP_DEFRAG_DEFER_MADVISE,
    THP_DEFRAG_MADVISE,
    THP_DEFRAG_NEVER,
    THP_DEFRAG_UNKNOWN,
    THP_ENABLED_ALWAYS,
    THP_ENABLED_MADVISE,
    THP_ENABLED_NEVER,
    THP_ENABLED_UNKNOWN,
    THP_PROCESS_AVAILABLE,
    THP_PROCESS_DISABLED,
    defrag_is_compaction_hazard,
    hugepage_auto_advice_mode,
    parse_bracketed_token,
    parse_thp_defrag,
    parse_thp_enabled,
    parse_thp_process_enabled,
    resolve_auto_mode,
    thp_policy_report,
    thp_probe_count,
)


# A buffer comfortably above the 8 MiB threshold, so that even the
# worst-case 2 MiB start-alignment loss leaves a multi-hugepage span.
comptime _BIG: Int = 24 * 1024 * 1024


# -----------------------------------------------------------------------------
# [a] Threshold — no advice below HUGEPAGE_MIN_ALLOC_BYTES.
# -----------------------------------------------------------------------------


def test_below_threshold_is_empty() raises:
    """Sub-threshold allocations get an empty span (no syscall)."""
    # A deliberately hugepage-aligned base, so the ONLY thing that can make
    # the span empty is the size threshold itself.
    var base = 64 * HUGEPAGE_BYTES
    assert_true(hugepage_span(base, 0).is_empty())
    assert_true(hugepage_span(base, 4096).is_empty())
    assert_true(hugepage_span(base, HUGEPAGE_BYTES).is_empty())
    assert_true(
        hugepage_span(base, HUGEPAGE_MIN_ALLOC_BYTES - 1).is_empty(),
        "one byte below the threshold must still be empty",
    )
    # ... and exactly AT the threshold, with an aligned base, it is NOT empty.
    assert_true(
        not hugepage_span(base, HUGEPAGE_MIN_ALLOC_BYTES).is_empty(),
        "at the threshold with an aligned base the span must be non-empty",
    )


# -----------------------------------------------------------------------------
# [b] The span contract, swept over adversarial addresses.
# -----------------------------------------------------------------------------


def _assert_span_contract(base_addr: Int, size: Int) raises:
    """Assert every clause of `hugepage_span`'s documented contract."""
    var span = hugepage_span(base_addr, size)
    if span.is_empty():
        # Empty is only legitimate when no aligned whole hugepage fits, or
        # we are under the size threshold.
        if size >= HUGEPAGE_MIN_ALLOC_BYTES and base_addr > 0:
            var s = (
                (base_addr + HUGEPAGE_BYTES - 1) // HUGEPAGE_BYTES
            ) * HUGEPAGE_BYTES
            var e = ((base_addr + size) // HUGEPAGE_BYTES) * HUGEPAGE_BYTES
            assert_true(
                e <= s,
                "span was empty but a valid aligned interval existed at base="
                + String(base_addr)
                + " size="
                + String(size),
            )
        return

    # CONTAINMENT — never before the base, never past the end.
    assert_true(
        span.offset >= 0,
        "span.offset < 0 (starts before the allocation) at base="
        + String(base_addr),
    )
    assert_true(
        span.offset + span.length <= size,
        "span runs past the end of the allocation at base="
        + String(base_addr)
        + " size="
        + String(size)
        + " offset="
        + String(span.offset)
        + " length="
        + String(span.length),
    )
    # ALIGNMENT — the advised address is hugepage-aligned.
    assert_equal(
        (base_addr + span.offset) % HUGEPAGE_BYTES,
        0,
        "advised start is not hugepage-aligned",
    )
    # WHOLE PAGES.
    assert_equal(
        span.length % HUGEPAGE_BYTES, 0, "span length is not a whole page count"
    )
    # MAXIMALITY — extending by one hugepage on either side must break
    # containment.
    assert_true(
        span.offset < HUGEPAGE_BYTES,
        "span start could have been one hugepage earlier (not maximal)",
    )
    assert_true(
        size - (span.offset + span.length) < HUGEPAGE_BYTES,
        "span end could have been one hugepage later (not maximal)",
    )


def test_span_contract_sweep() raises:
    """Sweep adversarial base/size combinations against the full contract."""
    var bases = List[Int]()
    bases.append(HUGEPAGE_BYTES)  # exactly aligned
    bases.append(HUGEPAGE_BYTES + 1)  # 1 past an aligned boundary
    bases.append(HUGEPAGE_BYTES - 1)  # 1 before an aligned boundary
    bases.append(HUGEPAGE_BYTES + 64)  # 64B-aligned, as OAB produces
    bases.append(4096)  # page-aligned, sub-hugepage
    bases.append(1)  # pathological
    bases.append(0x7F0000000000)  # realistic mmap-region address
    bases.append(0x7F0000000000 + 4096)
    bases.append(0x7F0000000000 + HUGEPAGE_BYTES - 4096)

    var sizes = List[Int]()
    sizes.append(HUGEPAGE_MIN_ALLOC_BYTES)
    sizes.append(HUGEPAGE_MIN_ALLOC_BYTES + 1)
    sizes.append(HUGEPAGE_MIN_ALLOC_BYTES + HUGEPAGE_BYTES - 1)
    sizes.append(_BIG)
    sizes.append(_BIG + 12345)
    sizes.append(800 * 1024 * 1024)  # a large concat destination
    sizes.append(1024 * 1024 * 1024 + 7)

    for bi in range(len(bases)):
        for si in range(len(sizes)):
            _assert_span_contract(bases[bi], sizes[si])

    # Degenerate / non-positive inputs must be total (no raise, empty span).
    assert_true(hugepage_span(0, _BIG).is_empty())
    assert_true(hugepage_span(-1, _BIG).is_empty())
    assert_true(hugepage_span(HUGEPAGE_BYTES, -1).is_empty())


# -----------------------------------------------------------------------------
# [c] DEFAULT-OFF — the default constructor advises nothing and reads no host
#     state.
# -----------------------------------------------------------------------------


def test_default_mode_is_off() raises:
    """`OwnedAlignedBuffer(capacity)` is `memory_advice=ADVICE_OFF`: the
    shipped default path issues no syscall and never consults the host THP
    probe. The empty configured value parses to the same OFF."""
    var before = thp_probe_count()
    var buf = OwnedAlignedBuffer(_BIG)
    assert_true(buf.capacity() >= _BIG)
    assert_equal(
        thp_probe_count(),
        before,
        "the default constructor must never probe the host",
    )
    assert_equal(
        parse_memory_advice(String("")),
        ADVICE_OFF,
        "an empty configured value must mean OFF",
    )


# -----------------------------------------------------------------------------
# [d] ADVICE_OFF is a genuine no-op on a real, large buffer.
# -----------------------------------------------------------------------------


def test_advice_off_is_noop() raises:
    """Mode ADVICE_OFF returns 0 without issuing any syscall, and leaves the
    buffer's shape untouched."""
    var buf = OwnedAlignedBuffer(_BIG)
    assert_equal(Int(buf.apply_memory_hint(ADVICE_OFF)), 0)
    assert_true(buf.is_aligned(), "alignment lost under ADVICE_OFF")
    assert_true(buf.capacity() >= _BIG)


# -----------------------------------------------------------------------------
# [e] The syscall oracle + shape preservation, per advice mode.
# -----------------------------------------------------------------------------


def _assert_hint_ok(mode: Int, label: String) raises:
    """Allocate a large buffer, apply `mode`, and assert the syscall succeeded
    and the buffer's shape is intact.

    NOTE the measured limit recorded in the file header: rc == 0 proves the
    kernel accepted the advice, NOT that the range is contained. Containment is
    [i]'s job.
    """
    var buf = OwnedAlignedBuffer(_BIG)
    var cap_before = buf.capacity()
    var len_before = buf.len()

    var rc = buf.apply_memory_hint(mode)
    assert_equal(
        Int(rc),
        0,
        "madvise returned "
        + String(Int(rc))
        + " for mode "
        + label
        + " — the kernel rejected the advice",
    )
    assert_true(buf.is_aligned(), "64B alignment lost after advice " + label)
    assert_equal(buf.capacity(), cap_before, "capacity changed by " + label)
    assert_equal(buf.len(), len_before, "length changed by " + label)


def test_hint_syscall_succeeds_all_modes() raises:
    """Every advice mode succeeds on a real >=threshold allocation."""
    _assert_hint_ok(ADVICE_HUGEPAGE, String("hugepage"))
    _assert_hint_ok(ADVICE_POPULATE, String("populate"))
    _assert_hint_ok(ADVICE_HUGEPAGE | ADVICE_POPULATE, String("both"))


# -----------------------------------------------------------------------------
# [f][g] Byte oracle — advice must not perturb a single byte.
# -----------------------------------------------------------------------------


def _assert_bytes_survive(mode: Int, label: String) raises:
    """Fill a >=threshold buffer with a position-dependent pattern, apply the
    advice, and verify EVERY byte survived.

    The pattern is written as u64 words (position-dependent, so a shifted or
    zeroed region cannot alias a correct one) and every word is re-read. A
    `MADV_POPULATE_WRITE` that zeroed already-written pages, or a span that
    reached into a neighbouring mapping, both show up here.
    """
    var buf = OwnedAlignedBuffer(_BIG)
    var words = _BIG // 8

    for i in range(words):
        buf.write_u64_le_at(i * 8, UInt64(i) * UInt64(0x9E3779B97F4A7C15))

    var rc = buf.apply_memory_hint(mode)
    assert_equal(Int(rc), 0, "madvise failed for mode " + label)

    for i in range(words):
        assert_equal(
            buf.read_u64_le_at(i * 8),
            UInt64(i) * UInt64(0x9E3779B97F4A7C15),
            "byte divergence at word " + String(i) + " after advice " + label,
        )
    assert_true(buf.is_aligned(), "alignment lost after advice " + label)


def test_bytes_survive_hugepage() raises:
    _assert_bytes_survive(ADVICE_HUGEPAGE, String("hugepage"))


def test_bytes_survive_populate() raises:
    """The strongest content oracle: MADV_POPULATE_WRITE actually walks and
    populates every page-table entry in the range. If it perturbed contents,
    or if the range were mis-computed, this diverges."""
    _assert_bytes_survive(ADVICE_POPULATE, String("populate"))
    _assert_bytes_survive(
        ADVICE_HUGEPAGE | ADVICE_POPULATE, String("hugepage|populate")
    )


# -----------------------------------------------------------------------------
# [h] The shipped default path (default ctor) is byte-correct.
# -----------------------------------------------------------------------------


def test_default_ctor_path_unchanged() raises:
    """End-to-end on the ACTUAL shipped path: construct a >=threshold buffer
    through `__init__` (the default `memory_advice=ADVICE_OFF`), and confirm the buffer
    behaves exactly as before — correct capacity, alignment, length, and
    full-range read/write fidelity."""
    var buf = OwnedAlignedBuffer(_BIG)
    assert_true(buf.capacity() >= _BIG, "capacity shrank")
    assert_equal(buf.capacity() % 64, 0, "capacity not 64B-padded")
    assert_equal(buf.len(), _BIG, "post-ctor length must equal capacity arg")
    assert_true(buf.is_aligned(), "ctor lost 64B alignment")

    # Write/read the extremes and the hugepage boundaries.
    var probes = List[Int]()
    probes.append(0)
    probes.append(8)
    probes.append(HUGEPAGE_BYTES - 8)
    probes.append(HUGEPAGE_BYTES)
    probes.append(HUGEPAGE_BYTES + 8)
    probes.append(_BIG // 2)
    probes.append(_BIG - 8)
    for i in range(len(probes)):
        var off = probes[i]
        buf.write_u64_le_at(off, UInt64(off) ^ UInt64(0xDEADBEEFCAFEF00D))
    for i in range(len(probes)):
        var off = probes[i]
        assert_equal(
            buf.read_u64_le_at(off),
            UInt64(off) ^ UInt64(0xDEADBEEFCAFEF00D),
            "readback mismatch at offset " + String(off),
        )

    # A sub-threshold buffer must be equally intact (the gate's other side).
    var small = OwnedAlignedBuffer(4096)
    assert_true(small.is_aligned())
    assert_equal(small.len(), 4096)
    small.write_u64_le_at(0, UInt64(0x1234567890ABCDEF))
    assert_equal(small.read_u64_le_at(0), UInt64(0x1234567890ABCDEF))


# -----------------------------------------------------------------------------
# [i] Runtime containment against a REAL tcmalloc address.
# -----------------------------------------------------------------------------


def test_runtime_span_is_contained() raises:
    """The span actually advised for a real allocation stays strictly inside
    that allocation.

    This is the overshoot oracle. `madvise`'s rc cannot provide it (BREAK 2 in
    the header: a +2 MiB overshoot still returned 0 because tcmalloc's arena
    keeps the neighbouring bytes mapped), so containment is asserted here
    directly against the buffer's own capacity.
    """
    # Several sizes, so we exercise a range of real base-address alignments.
    var sizes = List[Int]()
    sizes.append(HUGEPAGE_MIN_ALLOC_BYTES)
    sizes.append(HUGEPAGE_MIN_ALLOC_BYTES + 4096)
    sizes.append(_BIG)
    sizes.append(_BIG + 12345)

    for i in range(len(sizes)):
        var buf = OwnedAlignedBuffer(sizes[i])
        var span = buf.memory_hint_span()
        var cap = buf.capacity()
        assert_true(
            span.offset >= 0,
            "advised span starts before the allocation (size "
            + String(sizes[i])
            + ")",
        )
        assert_true(
            span.offset + span.length <= cap,
            "advised span runs past the allocation: offset="
            + String(span.offset)
            + " length="
            + String(span.length)
            + " capacity="
            + String(cap),
        )
        assert_equal(
            span.length % HUGEPAGE_BYTES,
            0,
            "advised span is not a whole number of hugepages",
        )
        # A >=3x-threshold buffer must actually produce a usable span; if this
        # ever goes empty the hint has silently stopped doing anything.
        if sizes[i] >= _BIG:
            assert_true(
                not span.is_empty(),
                "span unexpectedly empty for a "
                + String(sizes[i])
                + "-byte buffer — the hint would be a silent no-op",
            )


# =============================================================================
# `auto` — HOST THP DETECTION
# =============================================================================
#
# ⚠ THE ORACLE PROBLEM, and why [j]-[l] are PURE. The advice-ON path is
# unreachable on a host whose process tree carries `PR_SET_THP_DISABLE`, so a
# host-reading test would resolve to OFF there and assert nothing; and a test
# that asserted the LIVE resolved mode would be a function of whichever host
# runs it.
#
# So the decision table is tested as a PURE function of file CONTENTS ([j],
# [k], [l]), which is host-independent and covers every row including the ones
# no single host can produce. Only [m] (probe-once) and [n] (mode parsing)
# touch the live path, and both assert host-INDEPENDENT properties.
# =============================================================================


# -----------------------------------------------------------------------------
# [j] The sysfs parse table — every shape a kernel can emit, plus the junk.
# -----------------------------------------------------------------------------


def test_thp_sysfs_parse_table() raises:
    """Both THP sysfs files list every legal value and bracket the ACTIVE one.
    The bracketed token is the answer; everything else on the line is noise."""

    # -- the bracket extractor itself -----------------------------------------
    assert_equal(parse_bracketed_token(String("always [madvise] never")), "madvise")
    assert_equal(parse_bracketed_token(String("[always] madvise never")), "always")
    assert_equal(parse_bracketed_token(String("always madvise [never]")), "never")
    # No bracket at all / unterminated / empty brackets / empty file -> "".
    assert_equal(parse_bracketed_token(String("always madvise never")), "")
    assert_equal(parse_bracketed_token(String("always [madvise never")), "")
    assert_equal(parse_bracketed_token(String("[]")), "")
    assert_equal(parse_bracketed_token(String("")), "")

    # -- enabled: the three legal policies ------------------------------------
    assert_equal(
        parse_thp_enabled(String("always [madvise] never\n")),
        THP_ENABLED_MADVISE,
        "a common policy line: [madvise] is active",
    )
    assert_equal(
        parse_thp_enabled(String("[always] madvise never\n")), THP_ENABLED_ALWAYS
    )
    assert_equal(
        parse_thp_enabled(String("always madvise [never]\n")), THP_ENABLED_NEVER
    )

    # -- enabled: EVERY failure arm must be UNKNOWN, which resolves to OFF ----
    # This is the whole safety argument: a wrong guess here changes behaviour
    # on every host we ship to, silently.
    assert_equal(
        parse_thp_enabled(String("")),
        THP_ENABLED_UNKNOWN,
        "a MISSING/unreadable file reads as '' and must be UNKNOWN, not a policy",
    )
    assert_equal(parse_thp_enabled(String("always madvise never")), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled(String("[inline]")), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled(String("[MADVISE]")), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled(String("[ madvise ]")), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled(String("\x00\xff garbage")), THP_ENABLED_UNKNOWN)

    # -- defrag: FIVE values, one more than `enabled` -------------------------
    # A parser written against `enabled` and reused here mis-reads
    # `defer+madvise` — this is the case that catches it.
    assert_equal(
        parse_thp_defrag(
            String("always defer defer+madvise [madvise] never\n")
        ),
        THP_DEFRAG_MADVISE,
        "defer+madvise must not be mistaken for madvise",
    )
    assert_equal(
        parse_thp_defrag(String("always defer [defer+madvise] madvise never\n")),
        THP_DEFRAG_DEFER_MADVISE,
        "defer+madvise must NOT be read as `defer` or as `madvise`",
    )
    assert_equal(
        parse_thp_defrag(String("[always] defer defer+madvise madvise never\n")),
        THP_DEFRAG_ALWAYS,
    )
    assert_equal(
        parse_thp_defrag(String("always [defer] defer+madvise madvise never\n")),
        THP_DEFRAG_DEFER,
    )
    assert_equal(
        parse_thp_defrag(String("always defer defer+madvise madvise [never]\n")),
        THP_DEFRAG_NEVER,
    )
    assert_equal(parse_thp_defrag(String("")), THP_DEFRAG_UNKNOWN)
    assert_equal(parse_thp_defrag(String("[deferred]")), THP_DEFRAG_UNKNOWN)

    # -- the compaction-hazard classification --------------------------------
    # Reported, never acted on (see thp_policy.mojo's header) — but it is what
    # the sweep must watch, so it has to be right.
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_ALWAYS))
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_MADVISE))
    assert_true(
        defrag_is_compaction_hazard(THP_DEFRAG_DEFER_MADVISE),
        "defer+madvise DOES direct-compact for a MADV_HUGEPAGE caller",
    )
    assert_true(
        defrag_is_compaction_hazard(THP_DEFRAG_UNKNOWN),
        "UNKNOWN must report as a hazard — same fail-closed direction",
    )
    assert_true(not defrag_is_compaction_hazard(THP_DEFRAG_DEFER))
    assert_true(not defrag_is_compaction_hazard(THP_DEFRAG_NEVER))


# -----------------------------------------------------------------------------
# [k] /proc/self/status THP_enabled — THREE states, and ABSENT is the trap.
# -----------------------------------------------------------------------------


def test_thp_process_flag_parse() raises:
    """`PR_SET_THP_DISABLE` makes `MADV_HUGEPAGE` a strict no-op, and
    `/proc/self/status` reports it as `THP_enabled:`.

    ⚠ TWO INVERSIONS ARE GUARDED HERE:
      * the polarity is 1 = AVAILABLE, NOT "must be 0";
      * the field postdates ~kernel 5.17, so ABSENT means AVAILABLE. Reading
        absent-as-0 would silently disable the lever on every older host.
    """
    var with_1 = String(
        "Name:\tbench\nThreads:\t20\nTHP_enabled:\t1\nVoluntary_ctxt_switches:\t3\n"
    )
    var with_0 = String(
        "Name:\tbench\nThreads:\t20\nTHP_enabled:\t0\nVoluntary_ctxt_switches:\t3\n"
    )
    assert_equal(
        parse_thp_process_enabled(with_1),
        THP_PROCESS_AVAILABLE,
        "THP_enabled: 1 means THP IS AVAILABLE (the polarity a prior brief inverted)",
    )
    assert_equal(
        parse_thp_process_enabled(with_0),
        THP_PROCESS_DISABLED,
        "THP_enabled: 0 means PR_SET_THP_DISABLE is set for this process",
    )

    # ABSENT (pre-5.17 kernel) -> AVAILABLE. The second inversion.
    var no_field = String("Name:\tbench\nThreads:\t20\nSigQ:\t0/62841\n")
    assert_equal(
        parse_thp_process_enabled(no_field),
        THP_PROCESS_AVAILABLE,
        "an ABSENT THP_enabled field is a pre-5.17 kernel, NOT a disabled one",
    )
    # Unreadable /proc/self/status reads as "" -> also AVAILABLE. This field is
    # the EXPLAINER; the safety gate is `enabled`, whose missing arm is OFF.
    assert_equal(parse_thp_process_enabled(String("")), THP_PROCESS_AVAILABLE)

    # A name that merely CONTAINS the key must not match, and a value-less
    # field must not be read as disabled.
    assert_equal(
        parse_thp_process_enabled(String("NoTHP_enabled:\t0\n")),
        THP_PROCESS_AVAILABLE,
        "the key must anchor at the start of a line",
    )
    assert_equal(
        parse_thp_process_enabled(String("THP_enabled:\n")), THP_PROCESS_AVAILABLE
    )
    # Last line, no trailing newline.
    assert_equal(
        parse_thp_process_enabled(String("Threads:\t2\nTHP_enabled:\t0")),
        THP_PROCESS_DISABLED,
    )


# -----------------------------------------------------------------------------
# [l] The `auto` decision table, as a pure function of the parsed tokens.
# -----------------------------------------------------------------------------


def test_auto_resolution_table() raises:
    """Every row of the table in `thp_policy.mojo`'s header. `defrag` is varied
    across each row to pin that it does NOT change the answer today."""

    var defrags = List[Int]()
    defrags.append(THP_DEFRAG_ALWAYS)
    defrags.append(THP_DEFRAG_DEFER)
    defrags.append(THP_DEFRAG_DEFER_MADVISE)
    defrags.append(THP_DEFRAG_MADVISE)
    defrags.append(THP_DEFRAG_NEVER)
    defrags.append(THP_DEFRAG_UNKNOWN)

    for d in range(len(defrags)):
        var dg = defrags[d]

        # ROW 4 — the only row that turns the lever ON.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_MADVISE, dg, THP_PROCESS_AVAILABLE),
            ADVICE_HUGEPAGE,
            "enabled=[madvise] + THP available is the row MADV_HUGEPAGE exists for",
        )
        # ROW 2 — THP off host-wide.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_NEVER, dg, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
        )
        # ROW 3 — THE PESSIMISATION. On [always] the kernel already backs every
        # eligible VMA; the madvise buys no page and only opts the process into
        # direct compaction. "Does the host support it?" gets this row wrong.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_ALWAYS, dg, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
            "enabled=[always] must REFUSE — advising there is a pessimisation",
        )
        # ROW 5 — unparseable / missing / non-Linux.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_UNKNOWN, dg, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
            "anything unrecognised must FAIL CLOSED",
        )
        # ROW 1 — PR_SET_THP_DISABLE dominates every `enabled` value.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_MADVISE, dg, THP_PROCESS_DISABLED),
            ADVICE_OFF,
            "PR_SET_THP_DISABLE makes the advice a strict no-op — do not issue it",
        )
        assert_equal(
            resolve_auto_mode(THP_ENABLED_ALWAYS, dg, THP_PROCESS_DISABLED),
            ADVICE_OFF,
        )

    # `auto` NEVER resolves to POPULATE today. If a future pass makes `auto`
    # fall back to POPULATE under a compaction-hazard defrag, this assert is
    # where that decision must be re-stated deliberately.
    for d in range(len(defrags)):
        assert_true(
            resolve_auto_mode(THP_ENABLED_MADVISE, defrags[d], THP_PROCESS_AVAILABLE)
            != ADVICE_POPULATE,
            "auto does not select POPULATE — see thp_policy.mojo's defrag section",
        )


# -----------------------------------------------------------------------------
# [m] PROBE-ONCE — the freeze, asserted with a COUNTER (never a timing).
# -----------------------------------------------------------------------------


def test_auto_probe_is_read_once() raises:
    """The sysfs/procfs read happens at most ONCE per process.

    `parse_memory_advice("auto")` runs wherever a binary resolves its
    configured mode. Without the freeze, `auto` would put three open/read/close
    pairs on every resolution. This is the falsifier: remove the `_Global` and
    the count rises with the call count instead of pinning at 1.
    """
    var first = hugepage_auto_advice_mode()
    for _ in range(32):
        assert_equal(
            hugepage_auto_advice_mode(),
            first,
            "the frozen snapshot must return the same mode every time",
        )
    assert_equal(
        parse_memory_advice(String("auto")),
        first,
        "'auto' must resolve to exactly what the host probe decided",
    )
    assert_equal(parse_memory_advice(String("auto")), first)
    assert_equal(
        thp_probe_count(),
        1,
        "the host THP probe must run exactly once per process, not per call",
    )
    # And the resolved mode must be one the caller can actually act on.
    assert_true(
        first == ADVICE_OFF or first == ADVICE_HUGEPAGE,
        "auto resolved to an unexpected mode: " + String(first),
    )
    # The explain line is what makes a multi-host sweep attributable; assert it
    # is non-empty and names the resolved mode.
    var report = thp_policy_report()
    assert_true(report.byte_length() > 0)
    assert_true("auto=" in report, "the report must name the resolved mode")


# -----------------------------------------------------------------------------
# [n] THE CONFIGURED VALUE WINS OVER DETECTION, IN BOTH DIRECTIONS.
# -----------------------------------------------------------------------------


def test_parse_memory_advice_table() raises:
    """Every accepted spelling, plus one refused value. Detection can never
    override an explicit value: both directions are host-INDEPENDENT.

    Forcing ON where the host cannot deliver is deliberately harmless: the
    `madvise` returns an error the caller already ignores.
    """
    # OFF, whatever detection would have said.
    var offs = List[String]()
    offs.append(String(""))
    offs.append(String("0"))
    offs.append(String("off"))
    offs.append(String("false"))
    offs.append(String("no"))
    offs.append(String("none"))
    for i in range(len(offs)):
        assert_equal(
            parse_memory_advice(offs[i]),
            ADVICE_OFF,
            "explicit '" + offs[i] + "' must force OFF regardless of the host",
        )

    # ON, on a host detection might have refused.
    var ons = List[String]()
    ons.append(String("1"))
    ons.append(String("on"))
    ons.append(String("true"))
    ons.append(String("yes"))
    ons.append(String("hugepage"))
    for i in range(len(ons)):
        assert_equal(
            parse_memory_advice(ons[i]),
            ADVICE_HUGEPAGE,
            "explicit '" + ons[i] + "' must force ON regardless of the host",
        )

    assert_equal(parse_memory_advice(String("populate")), ADVICE_POPULATE)
    assert_equal(
        parse_memory_advice(String("both")), ADVICE_HUGEPAGE | ADVICE_POPULATE
    )

    # An unknown value is REFUSED, naming the value — never guessed.
    var raised = False
    try:
        _ = parse_memory_advice(String("hugepages"))
    except e:
        raised = True
        assert_true(
            "hugepages" in String(e),
            "the refusal must name the value, got: " + String(e),
        )
    assert_true(raised, "an unknown memory advice mode must raise")


# -----------------------------------------------------------------------------
# [o] AN EXPLICIT MODE ON THE CONSTRUCTOR — byte-correct, and no re-probe.
# -----------------------------------------------------------------------------


def test_explicit_mode_ctor_is_byte_correct() raises:
    """`OwnedAlignedBuffer(capacity, memory_advice=...)` advises at
    construction and leaves every byte, the capacity and the alignment
    intact. It takes the mode it is given and never re-probes the host."""
    var before = thp_probe_count()
    var modes = List[Int]()
    modes.append(ADVICE_HUGEPAGE)
    modes.append(ADVICE_POPULATE)
    modes.append(ADVICE_HUGEPAGE | ADVICE_POPULATE)
    for m in range(len(modes)):
        var buf = OwnedAlignedBuffer(_BIG, memory_advice=modes[m])
        assert_true(buf.capacity() >= _BIG, "capacity shrank")
        assert_true(buf.is_aligned(), "ctor lost 64B alignment")
        assert_equal(buf.len(), _BIG)
        buf.write_u64_le_at(0, UInt64(0x1234567890ABCDEF))
        buf.write_u64_le_at(_BIG - 8, UInt64(0xFEDCBA0987654321))
        assert_equal(buf.read_u64_le_at(0), UInt64(0x1234567890ABCDEF))
        assert_equal(buf.read_u64_le_at(_BIG - 8), UInt64(0xFEDCBA0987654321))
    assert_equal(
        thp_probe_count(), before, "an explicit mode must never re-probe the host"
    )


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    print("test_hugepage_hint: start")

    test_below_threshold_is_empty()
    print("  [a] below_threshold_is_empty -- PASS")

    test_span_contract_sweep()
    print("  [b] span_contract_sweep -- PASS")

    test_default_mode_is_off()
    print("  [c] default_mode_is_off -- PASS")

    test_advice_off_is_noop()
    print("  [d] advice_off_is_noop -- PASS")

    test_hint_syscall_succeeds_all_modes()
    print("  [e] hint_syscall_succeeds_all_modes -- PASS")

    test_bytes_survive_hugepage()
    print("  [f] bytes_survive_hugepage -- PASS")

    test_bytes_survive_populate()
    print("  [g] bytes_survive_populate -- PASS")

    test_default_ctor_path_unchanged()
    print("  [h] default_ctor_path_unchanged -- PASS")

    test_runtime_span_is_contained()
    print("  [i] runtime_span_is_contained -- PASS")

    test_thp_sysfs_parse_table()
    print("  [j] thp_sysfs_parse_table -- PASS")

    test_thp_process_flag_parse()
    print("  [k] thp_process_flag_parse -- PASS")

    test_auto_resolution_table()
    print("  [l] auto_resolution_table -- PASS")

    test_auto_probe_is_read_once()
    print("  [m] auto_probe_is_read_once -- PASS")

    test_parse_memory_advice_table()
    print("  [n] parse_memory_advice_table -- PASS")

    test_explicit_mode_ctor_is_byte_correct()
    print("  [o] explicit_mode_ctor_is_byte_correct -- PASS")

    print("  " + thp_policy_report())
    print("test_hugepage_hint: ALL PASS")
