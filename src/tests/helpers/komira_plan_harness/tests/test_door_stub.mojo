# door.mojo against the test-only plan door tests/door_stub/plan_door_stub.mojo,
# a Mojo shared library this test dlopens (staged as plan_door_stub.so; the
# stub's header lists its canned plans, which this file repeats byte for byte).
#
# What each test proves, and the defect it would catch:
#   test_door_a_returns_the_table
#       Door A's table renders to the expected canonical text
#       (require_table_matches), its stream was released exactly once (the
#       stub counts the release callback), and the stub's async runtime ran
#       the work on its own threads. Catches: a wrong cell; a stream released
#       twice or never; a dlopened Mojo library whose runtime did not run.
#   test_door_b_returns_the_same_table
#       Door B's probe-then-fill bytes decode to the same text; no stream is
#       released by it. Catches: an off-by-one fill length; a decode that
#       drops a chunk or a NULL.
#   test_abi_mismatch_is_a_named_refusal
#       A harness speaking another ABI version refuses the library by name
#       before opening a context. Catches: a door that skips the handshake.
#   test_fill_length_mismatch_is_caught
#       PLAN_SHORT_FILL makes the stub's fill report one byte fewer than its
#       probe: PLAN_DOOR_LENGTH_MISMATCH. Catches: a door that trusts the fill.
#   test_refusal_returns_the_error_and_leaves_out_alone
#       PLAN_REFUSE through both doors: PLAN_DOOR_REFUSED with the stub's
#       last_error, read back as UNSUPPORTED_REMOTE_FS(10); the out slots
#       untouched (the door checks its sentinels and would raise otherwise);
#       nothing to release. PLAN_DIRTY_REFUSE, which writes the out slot
#       before refusing: PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL through both doors.
#       Catches: a door that ignores a producer writing on a refusal.
#   test_fill_refusal_leaves_out_len_alone
#       PLAN_FILL_REFUSE (the probe answers, the fill refuses):
#       PLAN_DOOR_REFUSED with EXECUTION_FAILED(20). PLAN_FILL_DIRTY_REFUSE,
#       which writes out_len before refusing the fill:
#       PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL. Catches: a door that checks the
#       out slot on the probe's refusal only.
#   test_ok_without_a_live_stream_is_named
#       DOOR_OK with `*out` unwritten: PLAN_DOOR_OUT_NOT_WRITTEN; DOOR_OK with
#       a released `*out`: PLAN_DOOR_STREAM_RELEASED_ON_RETURN. Catches: a
#       door that calls get_schema through the sentinel (a crash) or drains a
#       released stream.
#   test_release_that_keeps_its_slot_is_named
#       PLAN_RELEASE_KEEPS_SLOT: the stream's release ran once and left
#       `release` set: PLAN_DOOR_STREAM_NOT_RELEASED. Catches: a door that
#       does not check the released-structure rule.
#   test_write_past_cap_is_named
#       PLAN_OVERRUN writes one byte at out[cap]: PLAN_DOOR_OVERRUN. Catches:
#       a door without the guard (the stream still decodes, so nothing else
#       would see it).
#   test_open_refusals
#       :plan_door_null_ctx (komira_ctx_new returns NULL):
#       PLAN_DOOR_CTX_NEW_FAILED; :plan_door_no_bytes (komira_plan_bytes
#       hidden): PLAN_DOOR_MISSING_SYMBOL naming it. Catches: a door that
#       keeps a NULL session, or binds symbols lazily.
#   test_unknown_plan_nul_bytes_and_empty_plan
#       A plan the stub does not know is MALFORMED(5); the canned plans hold a
#       NUL byte, so the table tests pass only if the door sends the declared
#       length; an empty plan is PLAN_DOOR_EMPTY_PLAN through both doors.
#       Catches: a door that measures the plan with strlen, or passes an empty
#       List's (absent) buffer.
#   test_flag_and_open_errors
#       `--plan-door=<path>` and `--plan-door <path>` give the path, no flag
#       is a named error, a value starting `--` is PLAN_DOOR_FLAG_BAD_VALUE,
#       a missing library is PLAN_DOOR_OPEN_FAILED, and a refusal text of
#       another shape is PLAN_DOOR_REFUSAL_UNREADABLE.

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import (
    PLAN_DOOR_ABI_VERSION,
    PlanDoor,
    door_path_from_args,
    parse_endpoint_refusal,
    require_table_matches,
)

comptime LIB = "./plan_door_stub.so"
"""The stub as test_data stages it (the BUCK names the destination)."""

comptime EXPECTED = (
    "#! komira-plan-conformance v1\n"
    "#  order: total\n"
    "#  float: ulps=0\n"
    "id:int64\tname:string?\tscore:float64\n"
    "10\talpha\t1.5\n"
    "20\t\\N\t-2.25\n"
    "30\tgamma\t0.125\n"
)


def _plan(tag: UInt8) -> List[UInt8]:
    return [UInt8(0x08), UInt8(0x02), UInt8(0x12), UInt8(0x00), tag]


comptime PLAN_TABLE: UInt8 = 1
comptime PLAN_REFUSE: UInt8 = 2
comptime PLAN_DIRTY_REFUSE: UInt8 = 3
comptime PLAN_SHORT_FILL: UInt8 = 4
comptime PLAN_OK_UNWRITTEN: UInt8 = 5
comptime PLAN_OK_RELEASED: UInt8 = 6
comptime PLAN_OVERRUN: UInt8 = 7
comptime PLAN_RELEASE_KEEPS_SLOT: UInt8 = 8
comptime PLAN_FILL_REFUSE: UInt8 = 9
comptime PLAN_FILL_DIRTY_REFUSE: UInt8 = 10


def _releases(door: PlanDoor) raises -> Int64:
    return door.instrument["komira_plan_door_stub_releases"]()


def _error_of(mut door: PlanDoor, plan: List[UInt8], door_b: Bool) -> String:
    """The error text a door call raises, or "" when it returns."""
    try:
        if door_b:
            _ = door.plan_bytes(plan)
        else:
            _ = door.plan_stream(plan)
    except e:
        return String(e)
    return String("")


def _assert_starts(text: String, prefix: String) raises:
    assert_true(text.startswith(prefix), String("expected `") + prefix + "...`, got `" + text + "`")


def test_door_a_returns_the_table() raises:
    var door = PlanDoor.open(LIB)
    assert_equal(door.abi_version, PLAN_DOOR_ABI_VERSION)
    assert_equal(_releases(door), 0)
    var table = door.plan_stream(_plan(PLAN_TABLE))
    assert_equal(table.num_chunks(), 2)
    require_table_matches(EXPECTED, table)
    assert_equal(_releases(door), 1, "Door A's stream must be released exactly once")
    var threads = door.instrument["komira_plan_door_stub_pool_threads"]()
    assert_true(threads >= 1, String("no chunk ran on the stub's runtime threads: ") + String(threads))
    # A second plan on the same session: one more release, not two.
    require_table_matches(EXPECTED, door.plan_stream(_plan(PLAN_TABLE)))
    assert_equal(_releases(door), 2)


def test_door_b_returns_the_same_table() raises:
    var door = PlanDoor.open(LIB)
    var table = door.plan_bytes(_plan(PLAN_TABLE))
    assert_equal(table.num_chunks(), 2)
    require_table_matches(EXPECTED, table)
    assert_equal(_releases(door), 0, "Door B exports no stream")
    # The parked result went with the fill: the next call executes again.
    require_table_matches(EXPECTED, door.plan_bytes(_plan(PLAN_TABLE)))


def test_abi_mismatch_is_a_named_refusal() raises:
    var msg = String("")
    try:
        _ = PlanDoor.open(LIB, expected_abi=PLAN_DOOR_ABI_VERSION + 1)
    except e:
        msg = String(e)
    _assert_starts(msg, "PLAN_DOOR_ABI_MISMATCH: ")
    assert_true(
        msg.endswith(
            String("reports door ABI ") + String(Int(PLAN_DOOR_ABI_VERSION))
            + ", the harness speaks " + String(Int(PLAN_DOOR_ABI_VERSION + 1))
        ),
        msg,
    )


def test_fill_length_mismatch_is_caught() raises:
    var door = PlanDoor.open(LIB)
    var msg = _error_of(door, _plan(PLAN_SHORT_FILL), True)
    _assert_starts(msg, "PLAN_DOOR_LENGTH_MISMATCH: the probe reported ")
    assert_true(msg.find(" bytes, the fill reported ") > 0, msg)
    # Door A answers the same plan with the table.
    require_table_matches(EXPECTED, door.plan_stream(_plan(PLAN_SHORT_FILL)))


def test_refusal_returns_the_error_and_leaves_out_alone() raises:
    var door = PlanDoor.open(LIB)
    for b in range(2):
        var msg = _error_of(door, _plan(PLAN_REFUSE), b == 1)
        _assert_starts(msg, "PLAN_DOOR_REFUSED: PLAN_ENDPOINT_UNSUPPORTED_REMOTE_FS(10): ")
        var r = parse_endpoint_refusal(msg)
        assert_equal(r.name, "PLAN_ENDPOINT_UNSUPPORTED_REMOTE_FS")
        assert_equal(r.code, 10)
        assert_equal(r.detail, "the stub refuses this plan")
        assert_equal(door.last_error(), "PLAN_ENDPOINT_UNSUPPORTED_REMOTE_FS(10): the stub refuses this plan")
        var dirty = _error_of(door, _plan(PLAN_DIRTY_REFUSE), b == 1)
        _assert_starts(dirty, "PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL: komira_plan_")
    assert_equal(_releases(door), 0, "a refusal exports no stream")
    # The session still answers after refusals, and the error is cleared.
    require_table_matches(EXPECTED, door.plan_stream(_plan(PLAN_TABLE)))
    assert_equal(door.last_error(), "")
    assert_equal(_releases(door), 1)


def test_fill_refusal_leaves_out_len_alone() raises:
    var door = PlanDoor.open(LIB)
    var msg = _error_of(door, _plan(PLAN_FILL_REFUSE), True)
    assert_equal(msg, "PLAN_DOOR_REFUSED: PLAN_ENDPOINT_EXECUTION_FAILED(20): the stub refuses the fill")
    var dirty = _error_of(door, _plan(PLAN_FILL_DIRTY_REFUSE), True)
    assert_equal(
        dirty, "PLAN_DOOR_OUT_TOUCHED_ON_REFUSAL: komira_plan_bytes refused the fill and wrote out_len = 77"
    )


def test_ok_without_a_live_stream_is_named() raises:
    var door = PlanDoor.open(LIB)
    _assert_starts(_error_of(door, _plan(PLAN_OK_UNWRITTEN), False), "PLAN_DOOR_OUT_NOT_WRITTEN: ")
    _assert_starts(_error_of(door, _plan(PLAN_OK_RELEASED), False), "PLAN_DOOR_STREAM_RELEASED_ON_RETURN: ")
    assert_equal(_releases(door), 0)
    # The session still answers.
    require_table_matches(EXPECTED, door.plan_stream(_plan(PLAN_TABLE)))


def test_release_that_keeps_its_slot_is_named() raises:
    var door = PlanDoor.open(LIB)
    var msg = _error_of(door, _plan(PLAN_RELEASE_KEEPS_SLOT), False)
    _assert_starts(msg, "PLAN_DOOR_STREAM_NOT_RELEASED: the stream's release callback ran")
    assert_equal(_releases(door), 1, "the release ran once; only its slot was left set")


def test_write_past_cap_is_named() raises:
    var door = PlanDoor.open(LIB)
    var msg = _error_of(door, _plan(PLAN_OVERRUN), True)
    _assert_starts(msg, "PLAN_DOOR_OVERRUN: komira_plan_bytes wrote past cap = ")


def _open_error(path: String) -> String:
    try:
        _ = PlanDoor.open(path)
    except e:
        return String(e)
    return String("")


def test_open_refusals() raises:
    assert_equal(
        _open_error("./plan_door_null_ctx.so"),
        "PLAN_DOOR_CTX_NEW_FAILED: ./plan_door_null_ctx.so: komira_ctx_new returned NULL",
    )
    assert_equal(
        _open_error("./plan_door_no_bytes.so"),
        "PLAN_DOOR_MISSING_SYMBOL: ./plan_door_no_bytes.so has no komira_plan_bytes",
    )


def test_unknown_plan_nul_bytes_and_empty_plan() raises:
    var door = PlanDoor.open(LIB)
    var plan = _plan(PLAN_TABLE)
    plan.append(UInt8(0))
    for b in range(2):
        var msg = _error_of(door, plan, b == 1)
        _assert_starts(msg, "PLAN_DOOR_REFUSED: PLAN_ENDPOINT_MALFORMED(5): ")
    var empty = List[UInt8]()
    for b in range(2):
        _assert_starts(_error_of(door, empty, b == 1), "PLAN_DOOR_EMPTY_PLAN: ")


def _flag_error(args: List[String]) -> String:
    try:
        _ = door_path_from_args(args)
    except e:
        return String(e)
    return String("")


def test_flag_and_open_errors() raises:
    var a: List[String] = ["prog", "--plan-door=./x.so"]
    assert_equal(door_path_from_args(a), "./x.so")
    var b: List[String] = ["prog", "--other", "--plan-door", "/abs/y.so"]
    assert_equal(door_path_from_args(b), "/abs/y.so")
    var none: List[String] = ["prog", "--plan-door="]
    var msg = String("")
    try:
        _ = door_path_from_args(none)
    except e:
        msg = String(e)
    _assert_starts(msg, "PLAN_DOOR_FLAG_MISSING: ")
    var bad1: List[String] = ["prog", "--plan-door=--verbose"]
    var bad2: List[String] = ["prog", "--plan-door", "--verbose"]
    _assert_starts(_flag_error(bad1), "PLAN_DOOR_FLAG_BAD_VALUE: --plan-door takes a path, not the flag `--verbose`")
    _assert_starts(_flag_error(bad2), "PLAN_DOOR_FLAG_BAD_VALUE: --plan-door takes a path, not the flag `--verbose`")
    msg = String("")
    try:
        _ = PlanDoor.open("./no_such_plan_door.so")
    except e:
        msg = String(e)
    _assert_starts(msg, "PLAN_DOOR_OPEN_FAILED: ./no_such_plan_door.so: ")
    msg = String("")
    try:
        _ = parse_endpoint_refusal("PLAN_DOOR_REFUSED: engine said no")
    except e:
        msg = String(e)
    _assert_starts(msg, "PLAN_DOOR_REFUSAL_UNREADABLE: ")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
