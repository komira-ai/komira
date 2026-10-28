# =============================================================================
# test_config_clock.mojo -- the server's configuration and its clocks.
# =============================================================================
#
#   config  a valid configuration keeps what it was given; each argument that no
#           server can run with is refused (an empty or unsafe token, an empty
#           or over-long default partition, a body limit or fold threshold under
#           1, ingest knobs the ingest refuses). Nothing has a default.
#   clocks  a fixed clock reads the same time every time; a step clock reads its
#           start, then moves by its step on each reading.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_kg import IngestConfig
from komira_kg_capture import CaptureClock, CaptureConfig, FixedClock, StepClock


def _make(
    token: String = "tok",
    partition: String = "p",
    body: Int = 10,
    fold: Int = 3,
) raises -> CaptureConfig:
    return CaptureConfig(token, partition, body, fold, IngestConfig.default())


def test_a_valid_configuration_keeps_its_arguments() raises:
    var cfg = _make("tok-1", "default-p", 123, 4)
    assert_equal(cfg.token, "tok-1")
    assert_equal(cfg.default_partition, "default-p")
    assert_equal(cfg.max_body_bytes, 123)
    assert_equal(cfg.compact_after_deltas, 4)
    assert_equal(cfg.ingest.cosine_k, IngestConfig.default().cosine_k)
    # The smallest values that are allowed.
    var least = _make("t", "p", 1, 1)
    assert_equal(least.max_body_bytes, 1)


def test_an_unusable_argument_is_refused() raises:
    with assert_raises(contains="token"):
        _ = _make(token="")
    with assert_raises(contains="token"):
        _ = _make(token="a b")
    with assert_raises(contains="default_partition"):
        _ = _make(partition="")
    with assert_raises(contains="default_partition"):
        _ = _make(partition="a\nb")
    with assert_raises(contains="max_body_bytes"):
        _ = _make(body=0)
    with assert_raises(contains="compact_after_deltas"):
        _ = _make(fold=0)
    var bad = IngestConfig.default()
    bad.cosine_k = 0
    with assert_raises():
        _ = CaptureConfig("t", "p", 10, 3, bad^)


def test_a_fixed_clock_does_not_move() raises:
    var clock = FixedClock(Int64(1_700))
    assert_equal(clock.now_ms(), Int64(1_700))
    assert_equal(clock.now_ms(), Int64(1_700))


def test_a_step_clock_moves_by_its_step_per_reading() raises:
    var clock = StepClock(Int64(100), Int64(25))
    assert_equal(clock.now_ms(), Int64(100))
    assert_equal(clock.now_ms(), Int64(125))
    assert_equal(clock.now_ms(), Int64(150))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
