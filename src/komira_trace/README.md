# komira_trace

A span tracer for code that runs on a fixed set of worker threads. A `Tracer`
holds one bounded single-producer ring per worker (`worker_id` 0 to
`num_workers - 1`); `start_span["name"]` and `end_span` each push one small
OPEN or CLOSE packet onto the calling worker's ring, with no lock and no
allocation once the ring exists. The span name is a compile-time string: its
FNV-1a id is computed at compile time and the name is registered in the
tracer's own name registry on first use (each `Tracer` keeps its own). A
drain (one thread) joins each OPEN with its CLOSE into a `SpanRecord` and hands the records to an exporter:
`JsonlFileExporter` writes one JSON object per line to a file,
`CapturingExporter` keeps them in memory. `format_span_json_line` is the one
place the span line's key order and number rendering are defined.

The tracer does not infer a parent: a child passes `parent_id`, and a span
with none is flagged as a root. A span still open at drain time comes out with
`end_ns = 0`. It does not sample, does not ship spans over a network, and does
not speak a tracing wire protocol. `MockClock` and `install_mock_ids` make
timestamps and ids deterministic for tests.

There is no facade: import from the sub-modules (`komira_trace.tracer`,
`komira_trace.exporter`, `komira_trace.span_record`, `komira_trace.testing`).

## Examples

Record a parent and a child span on worker 0, then drain them into memory:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED
from komira_trace.testing import MockClock
from komira_trace.tracer import Tracer

var tracer = Tracer(num_workers=1)
tracer.install_mock_clock(MockClock(start_ns=UInt64(5_000)))
tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(100))

var outer = tracer.start_span["query.execute"](worker_id=0)
var inner = tracer.start_span["scan.read"](worker_id=0, parent_id=outer)
assert_equal(tracer.depth_of(0), 2)
tracer.end_span(inner, worker_id=0)
tracer.end_span(outer, worker_id=0)
assert_equal(tracer.depth_of(0), 0)
assert_equal(tracer.name_registry_count(), 2)

var exporter = CapturingExporter()
tracer.drain_into_capture(exporter)
assert_equal(exporter.count(), 2)  # one record per span: OPEN joined with CLOSE
ref first = exporter.captured_spans[0]
assert_equal(first.span_id, UInt64(100))
assert_true(first.is_root())
assert_equal(first.status, SPAN_STATUS_CLOSED)
assert_equal(first.start_ns, UInt64(5_000))
ref second = exporter.captured_spans[1]
assert_equal(second.parent_id, UInt64(100))
assert_false(second.is_root())
assert_equal(tracer.ring_size(0), 0)  # the drain emptied the ring
```

The span line every producer writes, with its fixed key order:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_trace.exporter import format_span_json_line, trace_id_hex_128

var hex = trace_id_hex_128(UInt64(0x0102030405060708), UInt64(0x090A0B0C0D0E0F10))
assert_equal(hex, "0102030405060708090a0b0c0d0e0f10")
var line = format_span_json_line(hex, 7, 3, "a.b", 100, 250, 2, 1)
assert_equal(
    line,
    '{"trace_id":"0102030405060708090a0b0c0d0e0f10","span_id":7,'
    + '"parent_id":3,"name":"a.b","start_ns":100,"end_ns":250,'
    + '"worker_id":2,"flags":1}',
)
```
