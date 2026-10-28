# =============================================================================
# test_join_chain_layout_byte_equiv — the single-key chain-entry layouts
# (`nobi`, `fused`) produce the SAME join answer as the split layout, serial
# and parallel builds alike
# =============================================================================
#
# WHAT IS UNDER TEST. The `nobi` chain-entry layout omits the `build_indices`
# array from the single-key chained hash-join index (the probe emits `chain_idx`,
# which that array always equalled). The `fused` layout replaces the
# `build_keys` + `next_chain` PAIR with one interleaved 16-byte-record array.
# Both are claimed to be answer-preserving; this file is that claim's falsifier.
#
# THEY ARE THE SHIPPED DEFAULT, so this file's CONTROL is the split layout
# and it has to be asked for by name: it is the only independent answer this
# tree can compute for the shipped one.
#
# A VALUE ORACLE ALONE WOULD BE VACUOUS HERE: both arms of an answer-preserving
# change produce the same answer whether or not the new arm ever ran. So every
# case below asserts THREE things, and the first two are what make the third
# mean anything:
#
#   1. STRUCTURE — the arm actually changed the index. Under NOBI,
#      `len(build_indices) == 0` while `num_build == n`; under FUSED,
#      `len(build_keys) == len(next_chain) == 0` and `len(key_next) == 2n`.
#      A gate that silently declined fails here, not in the value compare.
#   2. FIRE — the process-wide build and probe counters moved. A probe that
#      never entered a specialised body cannot testify for the lever.
#   3. VALUE — every probe entry point emits the same thing as the control arm.
#
# THE COMPARISON IS EXACT (sequence, not multiset) FOR EVERY SERIAL BUILD.
# The serial build inserts in row order, so the chain order is fully determined
# and the two arms must agree POSITION BY POSITION. Only the PARALLEL Treiber
# build case relaxes to an order-insensitive compare, and only within a probe
# row's own match group: that build's per-bucket chain order is nondeterministic
# ACROSS BUILDS by construction (lock-free CAS push, `hash_chain_parallel_build`
# module header), which predates these levers and is not something they may be
# asked to preserve. Two runs of the SAME arm differ there too.
#
# COVERAGE, one case each: 1:1 keys; duplicate build keys (many-to-many chains,
# so the fused layout's chain walk is exercised for more than one step); NULL
# BUILD keys (the recorded-but-unlinked contract — the case where an
# unmatched-build sweep must still see a row the probe can never reach); NULL
# PROBE keys; an EMPTY build side; and a build side above the 250K
# `JOIN_BUILD_PARALLEL_THRESHOLD` so the parallel Treiber build writes the
# layout.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_build.join import HashJoinBuilder, ProbeInnerState
from komira_op_join_build.hash_chain_build_settings import (
    JOIN_BUILD_PARALLEL_THRESHOLD,
)
from komira_op_join_build.hash_chain_parallel_build import (
    hash_join_build_parallel,
)
from komira_op_join_build.join_layout_counter import (
    join_layout_build_fused_count,
    join_layout_build_nobi_count,
    join_layout_probe_fused_count,
    join_layout_probe_nobi_count,
    reset_join_layout_counters,
)


comptime I64 = DType.int64
comptime _POOL_WORKERS = 4
# Small enough that the chunked probe is forced to make several round trips on
# every fixture, which is the only way its mid-chain SAVE/RESUME path — the one
# place the layout is read twice for the same `chain_idx` — is executed.
comptime _CHUNK_CAP = 7

# ⭐ HOW MANY PROBE FIRES `_probe_digest` MUST PRODUCE, AND WHY IT IS AN
# EQUALITY RATHER THAN `> 0`.
#
# `join_layout_record_probe` is called once per ENTRY (never per row) from the
# DISPATCHER of every converted probe. `_probe_digest` drives NINE per-batch
# entries -- probe_inner_into, probe_left_into, probe_right, probe_full,
# probe_semi, probe_anti, probe_semi_count, probe_anti_count,
# count_inner_matches -- each contributing exactly one.
#
# The tenth is the CHUNKED cursor, which contributes exactly one MORE however
# many chunks it takes, because it uses the LATCHING recorder
# (`join_layout_record_probe_hot`). That is the streaming join's hot entry, called once per
# probe morsel, and an unconditional counter there would be ~50,000 contended
# atomics charged to the treatment arm.
#
# SO THE EQUALITY GUARDS BOTH DIRECTIONS AT ONCE.
#   * BELOW 10 -> some dispatcher lost its marker, i.e. a probe entry point can
#     take a specialised body with nothing able to observe that it did. That is
#     the state a lever with no firing observable ships in.
#   * ABOVE 10 -> the latch broke and the per-morsel entry is counting every
#     call again, which is a measurement contaminant, not a correctness bug --
#     and it is invisible to every value assertion in this file.
# `> 0` would have been satisfied by ONE wired entry point and would have seen
# neither.
comptime _EXPECTED_PROBE_ENTRIES = 10


# -----------------------------------------------------------------------------
# env + fixtures
# -----------------------------------------------------------------------------


# THE ARM IS AN ARGUMENT, NOT A SETTING. The four arms are selected by
# passing `nobi=` / `fused=` to `HashJoinBuilder.build` and
# `hash_join_build_parallel`, whose defaults are the SHIPPED values. So the
# CONTROL arm here, the split 4-array layout, is the one that has to be asked
# for explicitly, and the treatment arm is what a production caller gets by
# writing nothing: the structural assertions below fail if the DEFAULTS ever
# drift off the shipped layout.


def _pa(imm keys: List[Int64]) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    return arr^


def _pa_nullable(
    imm keys: List[Int64], imm nulls: List[Bool]
) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    for i in range(n):
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# -----------------------------------------------------------------------------
# The probe DIGEST — every converted entry point, flattened into one List[Int]
# -----------------------------------------------------------------------------
#
# One digest per (builder, probe column). Comparing digests compares EVERY
# entry point at once, so a lever that is right for INNER and wrong for LEFT
# cannot pass by being tested only where it is right.
#
# Layout of the digest, in order, each section preceded by its own length so a
# section that shrinks cannot be absorbed by the next one growing:
#   inner_into · inner_chunk · left_into · right · full · semi · anti ·
#   [semi_count, anti_count, count_inner_matches]


def _digest_pairs(
    mut out: List[Int], imm bm: List[Int], imm pm: List[Int]
) raises:
    if len(bm) != len(pm):
        raise Error("digest: build/probe match lists differ in length")
    out.append(len(bm))
    for i in range(len(bm)):
        out.append(bm[i])
        out.append(pm[i])


def _digest_list(mut out: List[Int], imm v: List[Int]):
    out.append(len(v))
    for i in range(len(v)):
        out.append(v[i])


def _probe_digest(
    imm b: HashJoinBuilder, imm probe: PrimitiveArray[I64]
) raises -> List[Int]:
    var out = List[Int]()

    var ib = List[Int]()
    var ip = List[Int]()
    b.probe_inner_into(probe, ib, ip)
    _digest_pairs(out, ib, ip)

    # Chunked INNER, through the resumable cursor, with a chunk capacity small
    # enough to force the mid-chain save/resume path.
    var cb = List[Int]()
    var cp = List[Int]()
    var chunk_b = List[Int]()
    chunk_b.resize(_CHUNK_CAP, 0)
    var chunk_p = List[Int]()
    chunk_p.resize(_CHUNK_CAP, 0)
    # PAYLOAD-INLINE: this fixture never arms it, so a one-element dummy is
    # correct -- the `pay=False` kernel instantiation never dereferences it.
    var chunk_pay = List[Int64]()
    chunk_pay.resize(1, Int64(0))
    var st = ProbeInnerState()
    while True:
        var got = b.probe_inner_chunk(
            probe,
            st,
            Span(chunk_b),
            Span(chunk_p),
            Span(chunk_pay),
            _CHUNK_CAP,
        )
        if got == 0:
            break
        for i in range(got):
            cb.append(chunk_b[i])
            cp.append(chunk_p[i])
    _digest_pairs(out, cb, cp)

    var lb = List[Int]()
    var lp = List[Int]()
    b.probe_left_into(probe, lb, lp)
    _digest_pairs(out, lb, lp)

    var r = b.probe_right(probe)
    var rb = r[0].copy()
    var rp = r[1].copy()
    _digest_pairs(out, rb, rp)

    var f = b.probe_full(probe)
    var fb = f[0].copy()
    var fp = f[1].copy()
    _digest_pairs(out, fb, fp)

    _digest_list(out, b.probe_semi(probe))
    _digest_list(out, b.probe_anti(probe))

    out.append(b.probe_semi_count(probe))
    out.append(b.probe_anti_count(probe))
    out.append(b.count_inner_matches(probe))
    return out^


def _assert_digest_equal(
    imm a: List[Int], imm b: List[Int], imm label: String
) raises:
    if len(a) != len(b):
        raise Error(
            label
            + ": digest LENGTH differs -- control "
            + String(len(a))
            + " vs arm "
            + String(len(b))
        )
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error(
                label
                + ": digest differs at "
                + String(i)
                + " -- control "
                + String(a[i])
                + " vs arm "
                + String(b[i])
            )


# -----------------------------------------------------------------------------
# Structural + fire assertions
# -----------------------------------------------------------------------------


def _assert_layout(
    imm b: HashJoinBuilder,
    n: Int,
    nobi: Bool,
    fused: Bool,
    imm label: String,
) raises:
    """THE ARM ACTUALLY CHANGED THE INDEX -- checked before any value compare.

    Without this, a gate that stopped firing would leave every value assertion
    in this file comparing the control arm against itself, and the whole suite
    would go green on a lever that no longer exists."""
    if b.num_build != n:
        raise Error(
            label
            + ": num_build "
            + String(b.num_build)
            + " != "
            + String(n)
        )
    if nobi:
        if len(b.build_indices) != 0:
            raise Error(
                label
                + ": NOBI arm still allocated build_indices ("
                + String(len(b.build_indices))
                + " entries)"
            )
    else:
        if len(b.build_indices) != n:
            raise Error(label + ": control arm lost build_indices")
        for i in range(n):
            # The invariant the whole NOBI lever rests on, asserted rather than
            # assumed. If this ever fails, the lever is WRONG, not merely unfired.
            if b.build_indices[i] != i:
                raise Error(
                    label
                    + ": build_indices["
                    + String(i)
                    + "] == "
                    + String(b.build_indices[i])
                    + ", identity invariant BROKEN"
                )
    if fused:
        if len(b.key_next) != 2 * n:
            raise Error(
                label
                + ": FUSED arm key_next length "
                + String(len(b.key_next))
                + " != "
                + String(2 * n)
            )
        if len(b.build_keys) != 0 or len(b.next_chain) != 0:
            raise Error(
                label + ": FUSED arm still allocated build_keys/next_chain"
            )
    else:
        if len(b.key_next) != 0:
            raise Error(label + ": control arm allocated key_next")
        if len(b.build_keys) != n or len(b.next_chain) != n:
            raise Error(label + ": control arm lost build_keys/next_chain")


# -----------------------------------------------------------------------------
# The case driver
# -----------------------------------------------------------------------------


def _build_serial(
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    use_bloom: Bool,
    nobi: Bool,
    fused: Bool,
) raises -> HashJoinBuilder:
    if len(build_nulls) == 0:
        return HashJoinBuilder.build(
            _pa(build), build_bloom=use_bloom, nobi=nobi, fused=fused
        )
    return HashJoinBuilder.build(
        _pa_nullable(build, build_nulls),
        build_bloom=use_bloom,
        nobi=nobi,
        fused=fused,
    )


def _build_parallel(
    imm build: List[Int64], nobi: Bool, fused: Bool
) raises -> HashJoinBuilder:
    """Drive the PRODUCTION adapter over the PRODUCTION dispatcher.

    This is the entry that THREADS the layout for the parallel path, so it is
    the one the test must call -- calling `chain_build_parallel` directly would
    skip the adapter's own defaults, which are half of what is under test."""
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return hash_join_build_parallel(
        disp, ct^, _pa(build), nobi=nobi, fused=fused
    )


def _check_serial(
    imm build: List[Int64],
    imm build_nulls: List[Bool],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    use_bloom: Bool,
    imm label: String,
) raises:
    var n = len(build)
    var pk: PrimitiveArray[I64]
    if len(probe_nulls) == 0:
        pk = _pa(probe)
    else:
        pk = _pa_nullable(probe, probe_nulls)

    var ctl = _build_serial(build, build_nulls, use_bloom, False, False)
    _assert_layout(ctl, n, False, False, label + "/control")
    var ctl_digest = _probe_digest(ctl, pk)
    _ = ctl^

    for arm in range(1, 4):
        var nobi = (arm & 1) != 0
        var fused = (arm & 2) != 0
        var arm_label = (
            label
            + "/nobi="
            + String(Int(nobi))
            + ",keynext="
            + String(Int(fused))
        )
        reset_join_layout_counters()
        var b = _build_serial(build, build_nulls, use_bloom, nobi, fused)
        _assert_layout(b, n, nobi, fused, arm_label)
        var d = _probe_digest(b, pk)
        _assert_digest_equal(ctl_digest, d, arm_label)
        # FIRE: the build recorded the layout AND at least one probe entry took
        # a specialised body. A value compare alone cannot see either.
        if nobi and join_layout_build_nobi_count() < 1:
            raise Error(arm_label + ": NOBI build never recorded a fire")
        if fused and join_layout_build_fused_count() < 1:
            raise Error(arm_label + ": FUSED build never recorded a fire")
        if nobi and join_layout_probe_nobi_count() != _EXPECTED_PROBE_ENTRIES:
            raise Error(
                arm_label
                + ": "
                + String(join_layout_probe_nobi_count())
                + " probe entries took the NOBI arm, expected exactly "
                + String(_EXPECTED_PROBE_ENTRIES)
            )
        if fused and join_layout_probe_fused_count() != _EXPECTED_PROBE_ENTRIES:
            raise Error(
                arm_label
                + ": "
                + String(join_layout_probe_fused_count())
                + " probe entries took the FUSED arm, expected exactly "
                + String(_EXPECTED_PROBE_ENTRIES)
            )
        _ = b^

    reset_join_layout_counters()
    _ = pk^


# -----------------------------------------------------------------------------
# cases
# -----------------------------------------------------------------------------


def test_unique_keys() raises:
    """1:1 -- every chain is at most one step, so this isolates the ENTRY read
    (key / build row) from the chain WALK."""
    var build = List[Int64]()
    for i in range(64):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(96):
        probe.append(Int64(i))  # 64 hits, 32 misses
    _check_serial(
        build, List[Bool](), probe, List[Bool](), True, String("unique")
    )


def test_duplicate_build_keys() raises:
    """MANY-TO-MANY. 8 distinct keys over 200 build rows -> 25-long chains, so
    the fused layout's `next` read runs 25 times per probe row and the chunked
    probe's mid-chain resume is forced."""
    var build = List[Int64]()
    for i in range(200):
        build.append(Int64(i % 8))
    var probe = List[Int64]()
    for i in range(40):
        probe.append(Int64(i % 12))  # keys 8..11 miss entirely
    _check_serial(
        build, List[Bool](), probe, List[Bool](), True, String("dup_build")
    )


def test_null_build_keys() raises:
    """A NULL build key is RECORDED (so RIGHT/FULL's unmatched-build sweep
    emits it) but NOT LINKED into a bucket. That row is reachable ONLY through
    the sweep, i.e. through `build_indices[i]` at an `i` no chain walk ever
    produces -- the one index the NOBI lever's `chain_idx` substitution does not
    come from a chain, and therefore the case most able to break it."""
    var build = List[Int64]()
    var bnulls = List[Bool]()
    for i in range(50):
        build.append(Int64(i % 7))
        bnulls.append(i % 5 == 0)  # 10 NULL build keys
    var probe = List[Int64]()
    for i in range(30):
        probe.append(Int64(i % 9))
    _check_serial(build, bnulls, probe, List[Bool](), True, String("null_build"))


def test_null_probe_keys() raises:
    """A NULL probe key matches nothing: dropped by INNER/SEMI, KEPT by
    ANTI/LEFT/FULL. It also encodes as 0, so a build key of 0 is present in this
    fixture deliberately -- without it the case cannot distinguish "NULL skipped"
    from "NULL matched 0"."""
    var build = List[Int64]()
    for i in range(40):
        build.append(Int64(i % 6))  # includes key 0
    var probe = List[Int64]()
    var pnulls = List[Bool]()
    for i in range(60):
        probe.append(Int64(i % 8))
        pnulls.append(i % 4 == 0)
    _check_serial(build, List[Bool](), probe, pnulls, True, String("null_probe"))


def test_empty_build() raises:
    """Zero build rows. Every array is empty on EVERY arm, which is exactly why
    `_assert_layout` reads `num_build` and the recorded flags rather than
    inferring the arm from a length."""
    var build = List[Int64]()
    var probe = List[Int64]()
    for i in range(16):
        probe.append(Int64(i))
    _check_serial(
        build, List[Bool](), probe, List[Bool](), False, String("empty_build")
    )


def test_small_build_no_bloom_arm() raises:
    """`build_bloom=False` -- the `_use_bloom` bypass, which is the arm the
    parallel adapter always produces. `probe_semi` / `probe_semi_count` ALSO
    switch loop arms at `build_n <= 4096`, and `build_n` is now read from
    `num_build` rather than `len(build_keys)`; under the fused layout the old
    spelling would be 0 and would silently take the small-build arm on a large
    build. This case pins the small side, `test_large_build_bloom_arm` the
    large one."""
    var build = List[Int64]()
    for i in range(30):
        build.append(Int64(i % 5))
    var probe = List[Int64]()
    for i in range(25):
        probe.append(Int64(i % 7))
    _check_serial(
        build, List[Bool](), probe, List[Bool](), False, String("no_bloom")
    )


def test_large_build_bloom_arm() raises:
    """> 4096 build rows: the two-stage-prefetch + bloom arm of
    `probe_semi`/`probe_anti`/`probe_semi_count`/`probe_anti_count`, and the arm
    whose stage-2 prefetch target had to move to `key_next` under the fused
    layout."""
    var build = List[Int64]()
    for i in range(5000):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(300):
        if i % 2 == 0:
            probe.append(Int64(i))
        else:
            probe.append(Int64(1_000_000 + i))
    _check_serial(
        build, List[Bool](), probe, List[Bool](), True, String("large_bloom")
    )


def test_parallel_treiber_build_above_threshold() raises:
    """THE PARALLEL BUILD, over the REAL 250K threshold -- no FORCE hook, so the
    tiling is production's.

    ⚠ THE FIXTURE'S BUILD KEYS ARE UNIQUE, AND THAT IS LOAD-BEARING, NOT
    INCIDENTAL. The Treiber push makes the per-bucket chain ORDER
    nondeterministic ACROSS BUILDS -- two runs of the SAME arm differ, which
    predates these levers (`hash_chain_parallel_build` module header) and is not
    something they can be asked to preserve. With unique build keys every probe
    row has AT MOST ONE match, so the emitted order is fixed by PROBE order
    alone and the compare below can stay EXACT, position by position, with no
    order-insensitive relaxation to weaken it. Do not add duplicate keys to this
    fixture without replacing the oracle at the same time -- the failure mode of
    forgetting is a FLAKY test, which is worse than a weak one."""
    var n = JOIN_BUILD_PARALLEL_THRESHOLD + 4096
    var build = List[Int64]()
    for i in range(n):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(2000):
        probe.append(Int64((i * 977) % (n + 500)))  # ~some hits, some misses
    var pk = _pa(probe)

    var ctl = _build_parallel(build, False, False)
    _assert_layout(ctl, n, False, False, String("parallel/control"))
    var ctl_digest = _probe_digest(ctl, pk)
    _ = ctl^

    for arm in range(1, 4):
        var nobi = (arm & 1) != 0
        var fused = (arm & 2) != 0
        var arm_label = (
            String("parallel/nobi=")
            + String(Int(nobi))
            + ",keynext="
            + String(Int(fused))
        )
        reset_join_layout_counters()
        var b = _build_parallel(build, nobi, fused)
        _assert_layout(b, n, nobi, fused, arm_label)
        var d = _probe_digest(b, pk)
        _assert_digest_equal(ctl_digest, d, arm_label)
        if nobi and join_layout_build_nobi_count() < 1:
            raise Error(arm_label + ": NOBI parallel build never fired")
        if fused and join_layout_build_fused_count() < 1:
            raise Error(arm_label + ": FUSED parallel build never fired")
        if nobi and join_layout_probe_nobi_count() != _EXPECTED_PROBE_ENTRIES:
            raise Error(
                arm_label
                + ": "
                + String(join_layout_probe_nobi_count())
                + " probe entries took the NOBI arm, expected exactly "
                + String(_EXPECTED_PROBE_ENTRIES)
            )
        if fused and join_layout_probe_fused_count() != _EXPECTED_PROBE_ENTRIES:
            raise Error(
                arm_label
                + ": "
                + String(join_layout_probe_fused_count())
                + " probe entries took the FUSED arm, expected exactly "
                + String(_EXPECTED_PROBE_ENTRIES)
            )
        _ = b^

    reset_join_layout_counters()
    _ = pk^


def test_control_arm_records_nothing() raises:
    """THE NEGATIVE CONTROL, and the reason the FIRE assertions above are not
    tautological: on the split layout, NEITHER counter moves. Without this, a
    recorder that incremented unconditionally would satisfy every `>= 1` above
    while proving nothing about which arm ran."""
    reset_join_layout_counters()
    var build = List[Int64]()
    for i in range(64):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(64):
        probe.append(Int64(i))
    var b = HashJoinBuilder.build(_pa(build), nobi=False, fused=False)
    var _d = _probe_digest(b, _pa(probe))
    if join_layout_build_nobi_count() != 0:
        raise Error("control arm recorded a NOBI build")
    if join_layout_build_fused_count() != 0:
        raise Error("control arm recorded a FUSED build")
    if join_layout_probe_nobi_count() != 0:
        raise Error("control arm recorded a NOBI probe entry")
    if join_layout_probe_fused_count() != 0:
        raise Error("control arm recorded a FUSED probe entry")
    _ = b^


def test_promoted_defaults() raises:
    """THE DEFAULTS ARE THE PROMOTED LAYOUT — the case this file's own header
    claims ("the structural assertions below now fail if the DEFAULTS ever
    drift off the promoted layout").

    EVERY other call site in this file passes `nobi=` / `fused=` EXPLICITLY, so
    a silent revert of either default to `False` would leave all of them GREEN:
    each asks for the arm it then asserts. Only a BARE `build(keys)` can see it.

    The parallel adapter's below-threshold fallback is checked in the same case
    because `hash_join_build_parallel`'s docstring makes matching defaults a
    STATED invariant ("a build under the threshold has to produce the SAME
    layout as one over it, or a probe would be handed a layout that depends on
    the build side's SIZE") and nothing else asserts it."""
    var n = 64
    var build = List[Int64]()
    for i in range(n):
        build.append(Int64(i))

    # Serial, NO layout arguments at all — what a production caller writes.
    var b = HashJoinBuilder.build(_pa(build))
    _assert_layout(b, n, True, True, String("defaults/serial"))
    _ = b^

    # The parallel adapter BELOW threshold: its serial fallback must STATE the
    # same layout, not inherit a different one.
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var pb = hash_join_build_parallel(disp, ct^, _pa(build))
    _assert_layout(pb, n, True, True, String("defaults/parallel-fallback"))
    _ = pb^


def main() raises:
    test_unique_keys()
    test_duplicate_build_keys()
    test_null_build_keys()
    test_null_probe_keys()
    test_empty_build()
    test_small_build_no_bloom_arm()
    test_large_build_bloom_arm()
    test_parallel_treiber_build_above_threshold()
    test_control_arm_records_nothing()
    test_promoted_defaults()
    print("test_join_chain_layout_byte_equiv OK (10 cases x 4 layout arms)")
