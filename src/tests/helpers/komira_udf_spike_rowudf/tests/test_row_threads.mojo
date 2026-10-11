# 4 engine threads on python_row.so through the row engine loop
# (native/row_engine.c: one pthread per engine thread, each opening its own
# context and instance and calling only those), over a 16-column input of
# which price_qty reads 2.
#
# What it proves, and the defect each part catches:
#   - with the producer's read set {price, qty} (read_sets.tsv), every
#     output is price * qty of its own row on every thread, calls == batches
#     (no per-row crossing), every exported argument array is released, and
#     the bytes crossed are exactly 2 columns x 8 bytes per row: only the
#     read set reaches the runtime (a runtime reading a field from the wrong
#     child; a leak; an engine that passes the whole input);
#   - with every column declared (16), the same values and 16 x 8 bytes per
#     row: the runtime takes any read set and the row reads the right child
#     by name, not by position;
#   - the engine names no runtime and no language;
#   - warm-up ends on the stability rule or its cap, and is counted.
#
# Mutant planted: row_call.c's field_columns exporting child 0's buffers for
# every field: red (bad values on every thread).

from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_rowudf.engine import RowEngine, RowReport, RowWorkload
from komira_udf_spike_rowudf.read_sets import load_read_sets, read_set_of

comptime ROWS = 1024
comptime BATCHES = 10


def _all_ok(r: RowReport, what: String) raises:
    assert_equal(r.status, 0, what + ": " + r.message)
    assert_equal(len(r.threads), 4, what)
    for i in range(len(r.threads)):
        ref t = r.threads[i]
        var w = what + ": thread " + String(i)
        assert_equal(t.status, 0, w + ": " + t.message)
        assert_equal(t.exported, t.released, w + ": arrays exported vs released")
        assert_equal(t.bad_values, 0, w)
        assert_equal(Int(len(t.samples)), BATCHES, w)
        assert_equal(t.calls, t.warmup_calls + BATCHES, w + ": one call per batch")
        assert_equal(t.rows, t.calls * ROWS, w)
        assert_true(t.warmup_calls >= 1 + 3 * 2, w + ": at least three windows of warm-up")
        assert_true(t.warm_stable or t.warmup_calls == 1 + 40 * 2, w + ": warm-up stopped early")


def _neutral() raises:
    for path in ["native/row_engine.c", "native/row_engine.h", "native/row_probe.c", "engine.mojo"]:
        var text = String("")
        with open(path, "r") as f:
            text = f.read().lower()
        for word in ["python", "numpy", "komira-test/", "node"]:
            assert_false(word in text, path + " names '" + word + "'")


def main() raises:
    _neutral()
    var sets = load_read_sets()
    var p = read_set_of(sets, "price_qty@16")
    assert_equal(len(p.input), 16)
    assert_equal(len(p.read_set), 2)
    var e = RowEngine("./python_row.so")
    assert_equal(e.status(), 0, e.message())

    var declared = e.run(RowWorkload(p.entry, p.input.copy(), p.read_set.copy(), "price", "qty", 4, ROWS, BATCHES, 2, 40))
    _all_ok(declared, "declared read set")
    assert_equal(declared.width, 16)
    assert_equal(declared.read_fields, 2)
    for t in declared.threads:
        assert_equal(t.bytes, t.calls * ROWS * 2 * 8, "declared: only the read set's two columns cross")

    var every = e.run(RowWorkload(p.entry, p.input.copy(), p.input.copy(), "price", "qty", 4, ROWS, BATCHES, 2, 40))
    _all_ok(every, "every column")
    assert_equal(every.read_fields, 16)
    for t in every.threads:
        assert_equal(t.bytes, t.calls * ROWS * 16 * 8, "every column: all sixteen cross")
    assert_true(every.bytes_per_row() == 8.0 * declared.bytes_per_row(), "16 / 2 columns of bytes per row")

    var missing: List[String] = ["price", "nope"]
    var bad = e.run(RowWorkload(p.entry, p.input.copy(), missing^, "", "", 1, ROWS, 1, 1, 1))
    assert_true("nope" in bad.message, "a read set naming a column the input lacks: " + bad.message)
    print("test_row_threads: ok")
