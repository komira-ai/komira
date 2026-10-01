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
# correctness is local to `_emit_string_field` (handles ASCII control
# bytes, quotes, backslash, and the standard JSON escapes).
#
# `CapturingExporter` is the test-only sibling — retains records in a
# `List[SpanRecord]` for assertions. Both impls satisfy the internal
# `SpanExporter` trait.
# =============================================================================

from std.io import FileHandle

from komira_obs.span_record import (
    SpanRecord,
    SpanLink,
    TRACE_ID_BYTES,
    DEFAULT_MAX_LINKS,
    SPAN_FLAG_ROOT,
    SPAN_FLAG_HAS_ERROR,
    SPAN_STATUS_OPEN,
    SPAN_STATUS_CLOSED,
)
from komira_obs.name_registry import NameRegistry


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


def _json_escape(imm s: String) -> String:
    """Minimal JSON string escape — handles `"`, `\\`, `\\n`, `\\t`, and
    `\\u00XX` for ASCII control bytes <0x20.
    """
    var out = String("")
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        var c = b[i]
        if c == UInt8(34):  # "
            out += String("\\\"")
        elif c == UInt8(92):  # backslash
            out += String("\\\\")
        elif c == UInt8(10):  # \n
            out += String("\\n")
        elif c == UInt8(13):  # \r
            out += String("\\r")
        elif c == UInt8(9):  # \t
            out += String("\\t")
        elif c < UInt8(32):
            out += String("\\u00") + _hex_byte(c)
        else:
            out += chr(Int(c))
    return out


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

    var s = String("{")
    s += String("\"trace_id\":\"") + _trace_id_to_hex(record.trace_id) + String("\",")
    s += String("\"span_id\":") + String(Int(record.span_id)) + String(",")
    s += String("\"parent_id\":") + String(Int(record.parent_id)) + String(",")
    s += String("\"name\":\"") + _json_escape(name_str) + String("\",")
    s += String("\"start_ns\":") + String(Int(record.start_ns)) + String(",")
    s += String("\"end_ns\":") + String(Int(record.end_ns)) + String(",")
    s += String("\"worker_id\":") + String(Int(record.worker_id)) + String(",")
    s += String("\"flags\":") + String(Int(record.flags))

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
            var slen = Int(registry.entries[i].name_len)
            var name = String("")
            for j in range(slen):
                name += chr(Int(registry.entries[i].name_bytes[j]))
            var line = String("{\"meta\":\"name\",\"name_id\":")
            line += String(Int(entry_id)) + String(",\"name\":\"")
            line += _json_escape(name) + String("\"}\n")
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
