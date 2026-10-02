# =============================================================================
# exporter.mojo — JsonlFileExporter + CapturingExporter (testing)
# =============================================================================
#
# ONE production exporter (`JsonlFileExporter`) that writes one JSON
# object per line in our own schema (the `SpanRecord` shape). The trait
# is internal; embedders DO NOT configure exporters (library-first: no
# process-global configuration).
#
# JSON is hand-emitted — no third-party JSON library. The escape
# correctness is local to `json_escape` (handles ASCII control
# bytes, quotes, backslash, and the standard JSON escapes).
#
# `CapturingExporter` is the test-only sibling — retains records in a
# `List[SpanRecord]` for assertions. Both impls satisfy the internal
# `SpanExporter` trait.
# =============================================================================

from std.io import FileHandle

from komira_trace.span_record import (
    SpanRecord,
    SpanLink,
    TRACE_ID_BYTES,
    DEFAULT_MAX_LINKS,
    SPAN_FLAG_ROOT,
    SPAN_FLAG_HAS_ERROR,
    SPAN_STATUS_OPEN,
    SPAN_STATUS_CLOSED,
)
from komira_name_registry import NameRegistry


# -----------------------------------------------------------------------------
# JSON helpers — hex encoding + minimal string-quote escape.
# -----------------------------------------------------------------------------


def _hex_byte(b: UInt8) -> String:
    """Render a single byte as two hex digits (lowercase)."""
    var hex = String("0123456789abcdef")
    var hb = hex.as_bytes()
    var hi = Int(b >> 4) & 0xF
    var lo = Int(b) & 0xF
    var out = String("")
    out += chr(Int(hb[hi]))
    out += chr(Int(hb[lo]))
    return out


def _trace_id_to_hex(trace_id: Array[UInt8, TRACE_ID_BYTES]) -> String:
    var out = String("")
    for i in range(TRACE_ID_BYTES):
        out += _hex_byte(trace_id[i])
    return out


def json_escape(imm s: String) -> String:
    """Minimal JSON string escape: `"`, `\\`, `\\n`, `\\r`, `\\t`, `\\b`, `\\f`,
    and `\\u00XX` for the other ASCII control bytes below 0x20.

    Every other byte, including each byte of a multi-byte UTF-8 sequence, is
    copied through unchanged. JSON needs no escaping above 0x7F, and
    re-encoding a byte as a code point (`chr(Int(byte))`) would turn each byte
    of a non-ASCII span name into two.
    """
    var out = String("")
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == UInt8(34):  # "
            out += String("\\\"")
            i += 1
        elif c == UInt8(92):  # backslash
            out += String("\\\\")
            i += 1
        elif c == UInt8(10):  # \n
            out += String("\\n")
            i += 1
        elif c == UInt8(13):  # \r
            out += String("\\r")
            i += 1
        elif c == UInt8(9):  # \t
            out += String("\\t")
            i += 1
        elif c == UInt8(8):  # \b
            out += String("\\b")
            i += 1
        elif c == UInt8(12):  # \f
            out += String("\\f")
            i += 1
        elif c < UInt8(32):
            out += String("\\u00") + _hex_byte(c)
            i += 1
        else:
            # A run of pass-through bytes, copied verbatim.
            var run_start = i
            while i < n:
                var rc = b[i]
                if rc == UInt8(34) or rc == UInt8(92) or rc < UInt8(32):
                    break
                i += 1
            var run = List[UInt8](capacity=i - run_start)
            for j in range(run_start, i):
                run.append(b[j])
            out += String(unsafe_from_utf8=Span(run))
    return out


def trace_id_hex_128(trace_hi: UInt64, trace_lo: UInt64) -> String:
    """Render a 128-bit trace id as 32 lowercase hex characters, big-endian
    over `[hi || lo]` (byte 0 is the most significant), the layout
    `SpanRecord.trace_id` uses."""
    var out = String("")
    for i in range(8):
        var shift = UInt64(56 - i * 8)
        out += _hex_byte(UInt8((trace_hi >> shift) & 0xFF))
    for i in range(8):
        var shift = UInt64(56 - i * 8)
        out += _hex_byte(UInt8((trace_lo >> shift) & 0xFF))
    return out


def _span_json_open(
    trace_id_hex: String,
    span_id: Int,
    parent_id: Int,
    name: String,
    start_ns: Int,
    end_ns: Int,
    worker_id: Int,
    flags: Int,
) -> String:
    """The span JSON object up to, not including, its closing brace."""
    var s = String("{")
    s += String("\"trace_id\":\"") + trace_id_hex + String("\",")
    s += String("\"span_id\":") + String(span_id) + String(",")
    s += String("\"parent_id\":") + String(parent_id) + String(",")
    s += String("\"name\":\"") + json_escape(name) + String("\",")
    s += String("\"start_ns\":") + String(start_ns) + String(",")
    s += String("\"end_ns\":") + String(end_ns) + String(",")
    s += String("\"worker_id\":") + String(worker_id) + String(",")
    s += String("\"flags\":") + String(flags)
    return s


def format_span_json_line(
    trace_id_hex: String,
    span_id: Int,
    parent_id: Int,
    name: String,
    start_ns: Int,
    end_ns: Int,
    worker_id: Int,
    flags: Int,
) -> String:
    """The span JSON object without links and without a trailing newline.

    This is the one place the span line's key order and number rendering are
    defined. `format_span_jsonl` appends the optional `links` array to it, and
    any other producer of span lines (the log drain's span path) calls it
    instead of keeping a copy.

        {"trace_id":"hex","span_id":N,"parent_id":N,"name":"foo",
         "start_ns":N,"end_ns":N,"worker_id":N,"flags":N}
    """
    return _span_json_open(
        trace_id_hex, span_id, parent_id, name, start_ns, end_ns, worker_id, flags
    ) + String("}")


# -----------------------------------------------------------------------------
# format_span_jsonl — the `SpanRecord` schema → one JSON line.
# -----------------------------------------------------------------------------


def format_span_jsonl(record: SpanRecord, registry: NameRegistry) -> String:
    """Render one `SpanRecord` as a single JSONL line (no trailing
    newline; the caller appends `\\n`).

    Schema:
        {"trace_id":"hex","span_id":N,"parent_id":N,"name":"foo",
         "start_ns":N,"end_ns":N,"worker_id":N,"flags":N,
         "links":[{"trace_id":"hex","span_id":N,"flags":N}, ...]}
    """
    var name_opt = registry.lookup(record.name_id)
    var name_str: String
    if name_opt:
        name_str = name_opt.value()
    else:
        # Unknown name_id — emit the raw hash so the analyzer can still
        # follow edges by ID. Drain-side the name registry SHOULD always
        # be populated before the first emit lands.
        name_str = String("__id_") + String(Int(record.name_id))

    var s = _span_json_open(
        _trace_id_to_hex(record.trace_id),
        Int(record.span_id),
        Int(record.parent_id),
        name_str,
        Int(record.start_ns),
        Int(record.end_ns),
        Int(record.worker_id),
        Int(record.flags),
    )

    if record.n_links > UInt8(0):
        s += String(",\"links\":[")
        var nl = Int(record.n_links)
        for li in range(nl):
            if li > 0:
                s += String(",")
            var link = record.links[li].copy()
            s += String("{\"trace_id\":\"") + _trace_id_to_hex(link.target_trace_id) + String("\",")
            s += String("\"span_id\":") + String(Int(link.target_span_id)) + String(",")
            s += String("\"flags\":") + String(Int(link.flags)) + String("}")
        s += String("]")
    s += String("}")
    return s


# -----------------------------------------------------------------------------
# JsonlFileExporter — production exporter.
# -----------------------------------------------------------------------------


struct JsonlFileExporter(Deinitable):
    """Write JSONL trace files. One JSON object per line.

    Append-only; opens the file at construction and writes via
    `FileHandle.write` per `flush_batch`. `shutdown()` closes the handle
    and is idempotent.
    """

    var _path: String
    var _file: Optional[FileHandle]
    var _records_written: Int64

    def __init__(out self, path: String) raises:
        self._path = path
        # Open in write mode (truncate). Append mode could be useful but
        # bench mode wants a fresh trace per run.
        self._file = Optional[FileHandle](FileHandle(path, "w"))
        self._records_written = Int64(0)

    def flush_record(mut self, record: SpanRecord, registry: NameRegistry) raises:
        if not self._file:
            raise Error("JsonlFileExporter: write after shutdown")
        var line = format_span_jsonl(record, registry) + String("\n")
        self._file.value().write(line)
        self._records_written += Int64(1)

    def flush_name_registry(mut self, registry: NameRegistry) raises:
        """Emit a JSONL "name_registry" record so the analyzer can join
        name_id → name when ingesting the file. One line per registered
        name, of shape `{"meta":"name","name_id":N,"name":"foo"}`.
        """
        if not self._file:
            raise Error("JsonlFileExporter: write after shutdown")
        for i in range(256):  # MAX_REGISTERED_NAMES
            var entry_id = registry.entries[i].name_id
            if entry_id == UInt32(0):
                continue
            var found = registry.lookup(entry_id)
            if not found:
                continue
            var name = found.value()
            var line = String("{\"meta\":\"name\",\"name_id\":")
            line += String(Int(entry_id)) + String(",\"name\":\"")
            line += json_escape(name) + String("\"}\n")
            self._file.value().write(line)

    def records_written(self) -> Int64:
        return self._records_written

    def shutdown(mut self) raises:
        """Close the file. Idempotent."""
        if self._file:
            self._file.value().close()
            self._file = Optional[FileHandle]()


# -----------------------------------------------------------------------------
# CapturingExporter — test-only. Retains records in memory.
# -----------------------------------------------------------------------------


struct CapturingExporter(Deinitable):
    """In-process exporter for tests. Stores every captured record in a
    `List[SpanRecord]` accessible to the test body.

    A first-class part of the test contract, not a debug
    helper. Tests assert against `captured_spans` directly.
    """

    var captured_spans: List[SpanRecord]

    def __init__(out self):
        self.captured_spans = List[SpanRecord]()

    def capture(mut self, record: SpanRecord):
        self.captured_spans.append(record.copy())

    def count(self) -> Int:
        return len(self.captured_spans)

    def clear(mut self):
        self.captured_spans = List[SpanRecord]()
