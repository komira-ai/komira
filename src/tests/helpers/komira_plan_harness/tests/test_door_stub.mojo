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
#   test_unknown_plan_and_nul_bytes
#       A plan the stub does not know is MALFORMED(5); the canned plans hold a
#       NUL byte, so the table tests pass only if the door sends the declared
#       length. Catches: a door that measures the plan with strlen.
#   test_flag_and_open_errors
#       `--plan-door=<path>` and `--plan-door <path>` give the path, no flag
#       is a named error, a missing library is PLAN_DOOR_OPEN_FAILED, and a
#       refusal text of another shape is PLAN_DOOR_REFUSAL_UNREADABLE.

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


def test_unknown_plan_and_nul_bytes() raises:
    var door = PlanDoor.open(LIB)
    var plan = _plan(PLAN_TABLE)
    plan.append(UInt8(0))
    for b in range(2):
        var msg = _error_of(door, plan, b == 1)
        _assert_starts(msg, "PLAN_DOOR_REFUSED: PLAN_ENDPOINT_MALFORMED(5): ")
    var empty = List[UInt8]()
    _assert_starts(_error_of(door, empty, False), "PLAN_DOOR_")


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
