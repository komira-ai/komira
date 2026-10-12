# `deferral_verdict`, the streaming join's deferral predicate: the wrapper
# `admits_deferral` agrees with it everywhere; the footprint cap, the traffic
# inequality and the memory rule each decide where they should and name
# themselves; the 4-byte index width admits payload widths the 8-byte pricing
# declined, while a selective join stays staged; the correctness refusals hold
# under `force`; the join state's rule arguments; and the verdict ledger.

from komira_op_join_probe.join_defer_verdict import (
    DEFER_ADMIT,
    DEFER_FOOTPRINT_CAP,
    DEFER_MEMORY,
    DEFER_NO_MATCHES,
    DEFER_NO_WIDTH,
    DEFER_SHAPE,
    DEFER_TRAFFIC,
    DEFER_UNPRICEABLE,
    DEFER_VERDICT_COUNT,
    defer_verdict_count,
    defer_verdict_fields,
    defer_verdict_note,
    defer_verdict_why,
    defer_verdict_word,
    DEFER_IDX_BYTES_PER_COL,
    deferral_verdict,
    reset_defer_verdict_counters,
)
from komira_op_join_probe.join_deferred import (
    admits_deferral,
    build_join_deferred_state,
)


comptime _IDXW_STALE = 8
comptime _IDXW_TRUE = 4


def _shape_probe_bytes(payload_w: Int, n: Int) -> Int:
    return (8 + payload_w) * n


def _shape_out_row_width(payload_w: Int) -> Int:
    return 8 + payload_w + 8 + payload_w


comptime _SHAPE_OUT_COLS = 4

comptime _SHAPE_N = 15360


def _verdict_at(payload_w: Int, idxw: Int, m: Int) -> Int:
    return deferral_verdict(
        _shape_probe_bytes(payload_w, _SHAPE_N),
        m,
        _shape_out_row_width(payload_w),
        False,
        _SHAPE_OUT_COLS,
        True,
        16,
        idxw,
    )


def _expect(
    got: Int, want: Int, imm what: String
) raises:
    if got != want:
        raise Error(
            what
            + ": expected `"
            + String(defer_verdict_word(want))
            + "` but the predicate said `"
            + String(defer_verdict_word(got))
            + "`"
        )


def test_the_wrapper_cannot_drift_from_the_verdict() raises:
    """`admits_deferral(x) == (deferral_verdict(x) == DEFER_ADMIT)`, everywhere."""
    var widths = [1, 2, 4, 8]
    var fanouts = [1, 2, 4, 10, 20]  # m = n * f / 4, i.e. 0.25n .. 5n
    var checked = 0
    for wi in range(len(widths)):
        for fi in range(len(fanouts)):
            for idxw in [4, 8]:
                var m = (_SHAPE_N * fanouts[fi]) // 4
                var pb = _shape_probe_bytes(widths[wi], _SHAPE_N)
                var w = _shape_out_row_width(widths[wi])
                var v = deferral_verdict(
                    pb, m, w, False, _SHAPE_OUT_COLS, True, 16, idxw
                )
                var a = admits_deferral(
                    pb, m, w, False, _SHAPE_OUT_COLS, True, 16, idxw
                )
                if a != (v == DEFER_ADMIT):
                    raise Error(
                        "admits_deferral disagrees with deferral_verdict at"
                        " payload_w=" + String(widths[wi])
                        + " m=" + String(m)
                        + " idxw=" + String(idxw)
                        + ": wrapper said " + String(a)
                        + " but the verdict was `"
                        + String(defer_verdict_word(v)) + "`"
                    )
                checked += 1
    var saw_admit = False
    var saw_decline = False
    for wi in range(len(widths)):
        for fi in range(len(fanouts)):
            var m = (_SHAPE_N * fanouts[fi]) // 4
            var v = _verdict_at(widths[wi], _IDXW_STALE, m)
            if v == DEFER_ADMIT:
                saw_admit = True
            else:
                saw_decline = True
    if not (saw_admit and saw_decline):
        raise Error(
            "the agreement grid is VACUOUS: it produced only "
            + ("admits" if saw_admit else "declines")
            + ". A wrapper that always returns the same value would pass."
        )
    print("  ok: wrapper == verdict over", checked, "points, both dispositions")


def test_the_footprint_cap_is_not_what_narrowing_defeats() raises:
    """The cap declines nothing across the payload-width ladder (8, 4, 2, 1
    bytes) of a 15,360-row, 4-output-column shape."""
    var prev_required = -1
    for payload_w in [8, 4, 2, 1]:
        var pb = _shape_probe_bytes(payload_w, _SHAPE_N)
        var w = _shape_out_row_width(payload_w)
        var required = (pb + w - 1) // w
        if prev_required >= 0 and required > prev_required:
            raise Error(
                "the footprint cap TIGHTENED as the payload narrowed to "
                + String(payload_w)
                + " B: it now needs m >= " + String(required)
                + " where the wider arm needed m >= " + String(prev_required)
                + ". Narrowing a PROBE column must relax this cap, never"
                " tighten it."
            )
        prev_required = required
        for idxw in [_IDXW_STALE, _IDXW_TRUE]:
            var v = _verdict_at(payload_w, idxw, _SHAPE_N)
            if v == DEFER_FOOTPRINT_CAP:
                raise Error(
                    "the FOOTPRINT CAP declined shape at payload_w="
                    + String(payload_w) + " idxw=" + String(idxw)
                    + "; narrowing a probe column must never trip the cap."
                )
    print("  ok: the cap is scale-invariant on the shape ladder and declines none")


def test_narrowing_a_build_only_column_DOES_tighten_the_cap() raises:
    """The asymmetry is real, intended, and pinned so nobody "fixes" it."""
    var probe_side = 16  # two INT64 probe columns, never narrowed
    var pb = probe_side * _SHAPE_N
    var prev_required = -1
    var saw_tighten = False
    for build_side in [16, 8, 4, 2]:
        var w = probe_side + build_side
        var required = (pb + w - 1) // w
        if prev_required >= 0 and required > prev_required:
            saw_tighten = True
        prev_required = required
    if not saw_tighten:
        raise Error(
            "narrowing a BUILD-ONLY output column did not tighten the footprint"
            " cap. The cap is a NON-REGRESSION bound against the staged arm's"
            " own peak; if it no longer tracks that peak it is no longer that"
            " bound."
        )
    print("  ok: build-side narrowing tightens the cap, as the bound requires")


def test_the_footprint_cap_still_refuses_an_overshoot() raises:
    """A retained probe larger than the whole staged output is REFUSED."""
    var pb = 64 * 1000000
    var m = 100
    var w = 128
    var v = deferral_verdict(pb, m, w, False, 8, True, 16, _IDXW_TRUE)
    _expect(
        v,
        DEFER_FOOTPRINT_CAP,
        "a 64 MB probe morsel retained to emit 100 rows",
    )
    var v2 = deferral_verdict(100000, 1000, 64, False, 1, True, 16, _IDXW_TRUE)
    _expect(
        v2,
        DEFER_FOOTPRINT_CAP,
        "a shape the traffic inequality admits and only the cap refuses",
    )
    print("  ok: the cap refuses an overshoot, and it is not shadowed by traffic")


def test_the_stale_index_width_declines_narrow_payloads() raises:
    """At IDXW=8 the 2- and 1-byte payload shapes are declined by traffic."""
    _expect(_verdict_at(8, _IDXW_STALE, _SHAPE_N), DEFER_ADMIT, "8 B payload, IDXW=8")
    _expect(_verdict_at(4, _IDXW_STALE, _SHAPE_N), DEFER_ADMIT, "4 B payload, IDXW=8")
    _expect(_verdict_at(2, _IDXW_STALE, _SHAPE_N), DEFER_TRAFFIC, "2 B payload, IDXW=8")
    _expect(_verdict_at(1, _IDXW_STALE, _SHAPE_N), DEFER_TRAFFIC, "1 B payload, IDXW=8")
    print("  ok: IDXW=8 defers 8/4-byte payloads and stages 2/1")


def test_the_index_width_correction_admits_the_whole_shape_ladder() raises:
    """At IDXW=4 every width defers -- the route stops moving with the width."""
    for payload_w in [8, 4, 2, 1]:
        _expect(
            _verdict_at(payload_w, _IDXW_TRUE, _SHAPE_N),
            DEFER_ADMIT,
            "payload_w=" + String(payload_w) + " at the corrected index width",
        )
    print("  ok: IDXW=4 admits 8/4/2/1 -- the route no longer tracks the width")


def test_the_correction_still_declines_the_selective_join_it_must() raises:
    """A selective join (one match in ten probe rows, 24-byte probe rows,
    40-byte output rows) stays STAGED at both widths, with margin."""
    var n = 15360
    var m = n // 10
    for idxw in [_IDXW_STALE, _IDXW_TRUE]:
        var v = deferral_verdict(24 * n, m, 40, False, 5, True, 16, idxw)
        if v == DEFER_ADMIT:
            raise Error(
                "the selective shape now ADMITS deferral at idxw=" + String(idxw)
                + "; deferring it moves more bytes than staging."
            )
    if deferral_verdict(24 * n, n // 2, 40, False, 5, True, 16, _IDXW_TRUE) == (
        DEFER_ADMIT
    ):
        raise Error(
            "the selective shape admits at FIVE TIMES its real fanout (0.5n vs 0.1n)."
            " The margin this test claims does not exist."
        )
    if deferral_verdict(
        24 * n, (n * 7) // 10, 40, False, 5, True, 16, _IDXW_TRUE
    ) != DEFER_ADMIT:
        raise Error(
            "the selective shape does not admit even at 0.7n fanout, so the predicate is"
            " refusing this family for a reason other than the one asserted --"
            " re-derive the bracket rather than loosening it."
        )
    print("  ok: the selective join stays staged at both index widths")


def test_each_refusal_names_its_own_line_and_force_does_not_bypass_them() raises:
    """Six ways to say no, each with its own code -- and `force` clears only
    the COST ones.
    """
    _expect(deferral_verdict(1024, 0, 32, False, 4, True), DEFER_NO_MATCHES, "m=0")
    _expect(deferral_verdict(1024, 10, 0, False, 4, True), DEFER_NO_WIDTH, "W=0")
    _expect(deferral_verdict(-1, 10, 32, False, 4, True), DEFER_UNPRICEABLE, "unpriceable")
    _expect(
        deferral_verdict(64 * 1000000, 100, 128, True, 8, True),
        DEFER_ADMIT,
        "force over a shape the cap refuses",
    )
    _expect(deferral_verdict(1024, 0, 32, True, 4, True), DEFER_NO_MATCHES, "forced m=0")
    _expect(deferral_verdict(1024, 10, 0, True, 4, True), DEFER_NO_WIDTH, "forced W=0")
    _expect(deferral_verdict(-1, 10, 32, True, 4, True), DEFER_UNPRICEABLE, "forced unpriceable")
    print("  ok: every refusal names its line; force clears only the cost rules")


def test_the_memory_rule_is_reachable_and_names_itself() raises:
    """The memory rule (the traffic rule off, or no column count) is a
    different line and says so."""
    var v = deferral_verdict(
        _shape_probe_bytes(8, _SHAPE_N), _SHAPE_N - 1, 32, False, 4, False, 16
    )
    _expect(v, DEFER_MEMORY, "memory rule just under the shape knife edge")
    _expect(
        deferral_verdict(
            _shape_probe_bytes(8, _SHAPE_N), _SHAPE_N, 32, False, 4, False, 16
        ),
        DEFER_ADMIT,
        "memory rule at the shape knife edge",
    )
    _expect(
        deferral_verdict(
            _shape_probe_bytes(8, _SHAPE_N), _SHAPE_N - 1, 32, False, 0, True, 16
        ),
        DEFER_MEMORY,
        "traffic rule on but no column count threaded",
    )
    print("  ok: the memory rule is reachable by both routes and names itself")


def test_the_state_carries_the_shipped_rule_by_default() raises:
    """A join's deferral state defaults to the shipped rule (the traffic rule,
    no forcing, 4-byte indices); each is an argument the caller can change."""
    if DEFER_IDX_BYTES_PER_COL != _IDXW_TRUE:
        raise Error("the priced index width is not the 4 bytes the gather reads")
    var st = build_join_deferred_state(2, 32, 4)
    if st[].force_defer or not st[].traffic_rule:
        raise Error("the default state is not the unforced traffic rule")
    if st[].idx_bytes_per_col != _IDXW_TRUE or st[].num_slots != 2:
        raise Error("the default state prices " + String(st[].idx_bytes_per_col))
    var old = build_join_deferred_state(0, 32, 4, True, False, _IDXW_STALE)
    if not old[].force_defer or old[].traffic_rule:
        raise Error("the state ignored its rule arguments")
    if old[].idx_bytes_per_col != _IDXW_STALE or old[].num_slots != 1:
        raise Error("the state ignored its index width or slot floor")
    print("  ok: the state defaults to the shipped rule and takes arguments")


def test_the_verdict_ledger_is_greppable_and_names_the_line() raises:
    """`name=value` with NO interior space, and `why=` in both directions."""
    reset_defer_verdict_counters()
    var line = defer_verdict_fields()
    if line.find("= ") >= 0:
        raise Error(
            "the verdict ledger contains `= ` (a SPACE after an equals): `"
            + line + "`: a grep for `defer_traffic=[0-9]` would match nothing."
        )
    for probe in [
        String("defer_admit="),
        String("defer_cap="),
        String("defer_traffic="),
        String("defer_memory="),
        String("defer_shape="),
        String("defer_nomatch="),
        String("defer_nowidth="),
        String("defer_unpriceable="),
        String("defer_why="),
    ]:
        if line.find(probe) < 0:
            raise Error(
                "the verdict ledger is missing `" + probe + "`. Every decline"
                " reason must be on the line or its zero is unreadable against"
                " the others. Line: `" + line + "`"
            )
    if line.find("defer_why=unreached") < 0:
        raise Error(
            "over ZEROED counters the ledger does not say `defer_why=unreached`."
            " All-zero is emitted both by `the site was never entered` and by"
            " `everything declined`; only the first is possible, and the"
            " instrument has to say which. Line: `" + line + "`"
        )
    for _ in range(7):
        defer_verdict_note(DEFER_TRAFFIC)
    defer_verdict_note(DEFER_ADMIT)
    if defer_verdict_count(DEFER_TRAFFIC) != 7:
        raise Error(
            "defer_verdict_note(DEFER_TRAFFIC) x7 recorded "
            + String(defer_verdict_count(DEFER_TRAFFIC))
        )
    if String(defer_verdict_why()) != String("traffic"):
        raise Error(
            "7 traffic declines against 1 admit derived `"
            + String(defer_verdict_why()) + "`, not `traffic`"
        )
    reset_defer_verdict_counters()
    for _ in range(5):
        defer_verdict_note(DEFER_ADMIT)
    for _ in range(4):
        defer_verdict_note(DEFER_TRAFFIC)
    for _ in range(3):
        defer_verdict_note(DEFER_FOOTPRINT_CAP)
    if String(defer_verdict_why()) != String("mixed"):
        raise Error(
            "a 5/4/3 split derived `" + String(defer_verdict_why())
            + "`; a plurality that is not a majority must read `mixed`"
        )
    reset_defer_verdict_counters()
    for c in range(DEFER_VERDICT_COUNT):
        defer_verdict_note(c)
    for c in range(DEFER_VERDICT_COUNT):
        if defer_verdict_count(c) != 1:
            raise Error(
                "verdict code " + String(c) + " (`"
                + String(defer_verdict_word(c)) + "`) recorded "
                + String(defer_verdict_count(c))
                + " -- a code that lands in another's counter makes both"
                " unreadable"
            )
    reset_defer_verdict_counters()
    print("  ok: the ledger is greppable, complete, and why= reads both ways")


def main() raises:
    test_the_wrapper_cannot_drift_from_the_verdict()
    test_the_footprint_cap_is_not_what_narrowing_defeats()
    test_narrowing_a_build_only_column_DOES_tighten_the_cap()
    test_the_footprint_cap_still_refuses_an_overshoot()
    test_the_stale_index_width_declines_narrow_payloads()
    test_the_index_width_correction_admits_the_whole_shape_ladder()
    test_the_correction_still_declines_the_selective_join_it_must()
    test_each_refusal_names_its_own_line_and_force_does_not_bypass_them()
    test_the_memory_rule_is_reachable_and_names_itself()
    test_the_state_carries_the_shipped_rule_by_default()
    test_the_verdict_ledger_is_greppable_and_names_the_line()
    print("test_join_defer_verdict OK (11 cases)")
