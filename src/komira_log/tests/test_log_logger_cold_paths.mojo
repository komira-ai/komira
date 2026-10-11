# =============================================================================
# test_log_logger_cold_paths.mojo — the arms of the typed `Logger` and of
# `emit_erased` that only a disabled engine, an arg set too big for the inline
# blob, a `Field` on the synchronous path, or a full ring reaches:
#
#   * a disabled engine: the typed calls and the `*_text` calls emit nothing;
#   * an arg blob over 48 bytes spills to the ring arena and still decodes
#     whole (typed and erased);
#   * on a thread that is not a bound worker, a `Field` renders as a trailing
#     `key=value`, not as a `{}` positional (typed and erased);
#   * an erased WARN whose ring push is refused escalates to a synchronous
#     write, args and fields included; an erased INFO in the same spot is
#     dropped (the never-drop rule is WARN and above).
#
# Lines written synchronously go to a single-file sink the case then reads.
# =============================================================================

from std.io import FileHandle
from std.os import remove
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir

from komira_log import SharedEngine, Logger
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE, LEVEL_INFO, LEVEL_WARN
from komira_log.log_arg import ArgI64, ArgStr, Field
from komira_log.log_value import LogValue as LV
from komira_log.logger_erased import emit_erased
from komira_log.engine.log_event_record import LogEventRecord
from komira_log.engine.rotation import RotationPolicy


def _base(tag: String) raises -> String:
    """A path under this run's private $TEST_TMPDIR. Raises when it is unset:
    a fixed /tmp path would be shared by concurrent runs."""
    return test_tmpdir() + String("/komira_log_cold_") + tag


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _engine_with_file(tag: String) raises -> SharedEngine:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    var eng = SharedEngine(num_workers=1, filter=f^)
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    return eng^


def _sink_text(mut eng: SharedEngine, tag: String) raises -> String:
    # No fsync: a write(2) is visible to a read at once, and an fsync on a
    # loaded disk can take tens of seconds.
    var f = FileHandle(_base(tag) + ".log", "r")
    var s = String(f.read())
    f.close()
    _rm(_base(tag) + ".log")
    return s^


def _long(n: Int) -> String:
    var s = String("")
    for i in range(n):
        s += String(chr(ord("a") + i % 26))
    return s^


def _fill(mut eng: SharedEngine) raises:
    var n = 0
    while n < 1 << 20 and eng.ring(0).try_push(LogEventRecord()):
        n += 1
    assert_false(eng.ring(0).try_push(LogEventRecord()), "ring(0) is full")


def test_a_disabled_engine_takes_nothing_from_the_typed_logger() raises:
    var tag = String("disabled")
    var eng = _engine_with_file(tag)
    eng.bind_worker_thread(UInt16(0))
    eng.set_enabled(False)
    var logger = Logger.borrow(eng)
    logger.error["cov disabled {}", "cov_cold"](ArgI64(1))
    logger.error_text["cov_cold"](String("cov disabled text"))
    var empty = eng.ring(0).is_empty()
    var text = _sink_text(eng, tag)
    assert_true(empty, "no record on the ring")
    assert_equal(text, String(""), "and no synchronous line")


def test_a_typed_arg_set_over_the_inline_blob_spills_and_decodes() raises:
    var tag = String("typed_spill")
    var eng = _engine_with_file(tag)
    eng.bind_worker_thread(UInt16(0))
    var big = _long(100)
    var logger = Logger.borrow(eng)
    logger.info["cov spill {}", "cov_cold"](ArgStr(big.copy()))
    var lines = eng.drain_worker_to_lines(0, 8)
    _ = _sink_text(eng, tag)
    assert_equal(len(lines), 1)
    assert_true(
        lines[0].endswith(String("cov spill ") + big),
        String("the 100-byte arg came back whole: ") + lines[0],
    )


def test_a_typed_field_off_worker_renders_as_key_value() raises:
    var tag = String("typed_field")
    var eng = _engine_with_file(tag)
    var logger = Logger.borrow(eng)
    logger.info["cov typed fb {}", "cov_cold"](
        ArgStr(String("p")), Field(String("k"), ArgI64(5))
    )
    var text = _sink_text(eng, tag)
    assert_true(
        String("INFO [cov_cold] cov typed fb p k=5\n") in text,
        String("got <") + text + ">",
    )


def test_an_erased_field_off_worker_renders_as_key_value() raises:
    var tag = String("erased_field")
    var eng = _engine_with_file(tag)
    emit_erased[LEVEL_INFO, "cov_cold"](
        eng, "cov erased fb {}", LV.text(String("p")), LV.field(String("k"), LV.i64(5))
    )
    var text = _sink_text(eng, tag)
    assert_true(
        String("INFO [cov_cold] cov erased fb p k=5\n") in text,
        String("got <") + text + ">",
    )


def test_an_erased_arg_set_over_the_inline_blob_spills_and_decodes() raises:
    var tag = String("erased_spill")
    var eng = _engine_with_file(tag)
    eng.bind_worker_thread(UInt16(0))
    var big = _long(100)
    emit_erased[LEVEL_INFO, "cov_cold"](eng, "cov erased spill {}", LV.text(big.copy()))
    var lines = eng.drain_worker_to_lines(0, 8)
    _ = _sink_text(eng, tag)
    assert_equal(len(lines), 1)
    assert_true(
        lines[0].endswith(String("cov erased spill ") + big),
        String("the 100-byte arg came back whole: ") + lines[0],
    )


def test_an_erased_warn_on_a_full_ring_escalates_with_its_fields() raises:
    var tag = String("erased_escalate")
    var eng = _engine_with_file(tag)
    eng.bind_worker_thread(UInt16(0))
    _fill(eng)
    emit_erased[LEVEL_INFO, "cov_cold"](eng, "cov erased info dropped")
    emit_erased[LEVEL_WARN, "cov_cold"](
        eng, "cov erased esc {}", LV.text(String("p")), LV.field(String("k"), LV.i64(5))
    )
    var text = _sink_text(eng, tag)
    assert_true(
        String("WARN [cov_cold] cov erased esc p k=5\n") in text,
        String("the WARN escalated whole: <") + text + ">",
    )
    assert_false(
        String("cov erased info dropped") in text,
        "an INFO on a full ring is dropped, not escalated",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
