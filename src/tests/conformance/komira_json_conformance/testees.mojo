# =============================================================================
# testees.mojo -- each JSON parser komira ships, behind one shape
# =============================================================================
#
# A testee takes one suite file's raw bytes and returns when its parser
# accepted the text, or raises when the parser rejected it. Two harness
# errors are not the parser's rejection, and runner.mojo tells them apart by
# their first word: NOT_UTF8 (the BOUNDARY verdict: the entry point takes a
# String and the file is not UTF-8, so the parser never ran) and MISREAD (the
# parser returned, but its output does not represent the text). What a
# verdict must be is the suite's (suite.mojo); which wrong verdicts are known
# is the allowlist's (gate.mojo).
#
# The parsers, by the name their test and allowlist carry:
#
#   komira_json         parse_json_bytes: the strict RFC 8259 parser most of
#                       komira's JSON readers sit on (kci's manifests, release
#                       sets and API documents, the cloud SDKs, proto3-JSON).
#                       komira_avro, kci_logs, komira_log_query and
#                       komira_connect have scanners of their own, below.
#                       Takes bytes.
#   komira_proto_codec  decode_json[komira_wkt.Value]: proto3-JSON decode of
#                       google.protobuf.Value, the message type whose JSON form
#                       is any JSON value, so every y_ text is a valid input.
#                       Takes a String.
#   komira_jsonl        infer_jsonl_schema, then materialize_jsonl_to_batch
#                       with the inferred schema: the engine's JSONL reader,
#                       on the text as one line. Takes bytes. komira_jsonl
#                       reads one object per line (its own rule: JSONL allows
#                       any value, but a record becomes a row), so the text
#                       is read right when its top level is an object and
#                       it comes back as exactly one row. A returned batch is
#                       MISREAD when the top level is anything else (the
#                       reader refuses such a line; only a text of nothing
#                       but whitespace comes back as zero rows and no error)
#                       or when an object is not one row.
#   komira_json_index   CRASH-ONLY. extract_column over a one-row STRING
#                       column holding the file's bytes verbatim, with `->`
#                       and with `->>`, on the path of the text's first key
#                       when it starts with an object (`a` otherwise); then
#                       the json_index string unescaper on the text's first
#                       string token. The kernel is lenient by contract: a
#                       malformed row is NULL, never an error, so its
#                       verdicts mean nothing and only a crash is gated.
#   komira_avro         The Avro reader's path for untrusted schema text: the
#                       file's bytes as the `avro.schema` value of an OCF
#                       header (magic, a one-entry metadata map, the end of
#                       the map, a sync marker), through decode_ocf_header and
#                       OcfHeader.parse_schema. The bytes are wrapped, never
#                       changed. An error raised after the JSON parse, while
#                       the value is read as a schema (_avro_schema_errors),
#                       means the text was accepted as JSON and is not a
#                       schema: acceptance here. Every other error is a
#                       rejection.
#   komira_log_query    is_json_object_text: the grammar check the log route
#                       makes before it embeds a stored blob verbatim. Its
#                       contract is exactly one object, so a y_ text whose top
#                       level is not an object is rightly refused (listed).
#                       Takes a String.
#   kci_logs            CRASH-ONLY. json_skip_value over the whole text as one
#                       value followed only by whitespace, json_scan_string on
#                       the raw bytes from the text's first `"`, and the three
#                       body parsers built on them (CloudWatch GetLogEvents,
#                       Cloud Logging entries.list, the run-log API) on the
#                       text. A skipper that checks nothing inside a value and
#                       parsers that never raise by design: only a crash is
#                       gated.
#   komira_connect      CRASH-ONLY. parse_connect_error_json on the raw bytes:
#                       a tolerant scan for two keys, not a JSON parser.
#
# One testee is not a parser: `abort_probe` (CRASH-ONLY, test_abort_path.mojo)
# aborts the process on a text that is `null` with only whitespace around it
# (one suite file, y_structure_lonely_null.json) and accepts every other
# text. It exists so the ABORTS: child path (runner.mojo) runs in a build
# while no parser aborts; it has no allowlist file and is in no parser list.
#
# A String-taking entry point cannot be handed ill-formed UTF-8 (a String is
# UTF-8 by type): such a file is converted with a checking conversion and,
# when that fails, refused with NOT_UTF8 before the parser runs.
# =============================================================================

from std.os import abort

from kci_logs import json_scan_string, json_skip_space, json_skip_value
from kci_logs.aws_cloudwatch_query import parse_get_log_events_body
from kci_logs.gcp_logging_query import parse_entries_list_body
from kci_logs.run_log_tail import parse_run_logs_body
from komira_avro import decode_ocf_header
from komira_connect import parse_connect_error_json
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_json import parse_json_bytes
from komira_json_index.json_extract_kernel import extract_column
from komira_json_index.parse_string import parse_string
from komira_jsonl import infer_jsonl_schema
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_log_query import is_json_object_text
from komira_proto_codec import decode_json
from komira_wkt import Value

comptime PARSER_JSON = "komira_json"
comptime PARSER_PROTO_CODEC = "komira_proto_codec"
comptime PARSER_JSONL = "komira_jsonl"
comptime PARSER_JSON_INDEX = "komira_json_index"
comptime PARSER_AVRO = "komira_avro"
comptime PARSER_LOG_QUERY = "komira_log_query"
comptime PARSER_KCI_LOGS = "kci_logs"
comptime PARSER_CONNECT = "komira_connect"
# Not a parser: a testee that aborts on one suite file (module header).
comptime PARSER_ABORT_PROBE = "abort_probe"
# The file abort_probe aborts on, and the text its abort prints.
comptime ABORT_PROBE_FILE = "y_structure_lonely_null.json"
comptime ABORT_PROBE_TEXT = "abort_probe: aborting on purpose"

# The first word of the harness's two errors (module header).
comptime NOT_UTF8 = "NOT_UTF8"
comptime MISREAD = "MISREAD"


def parser_names() -> List[String]:
    return [
        String(PARSER_JSON),
        String(PARSER_PROTO_CODEC),
        String(PARSER_JSONL),
        String(PARSER_JSON_INDEX),
        String(PARSER_AVRO),
        String(PARSER_LOG_QUERY),
        String(PARSER_KCI_LOGS),
        String(PARSER_CONNECT),
    ]


def is_crash_only(parser: String) -> Bool:
    """The parsers whose verdicts are not gated (module header)."""
    return (
        parser == PARSER_JSON_INDEX
        or parser == PARSER_KCI_LOGS
        or parser == PARSER_CONNECT
        or parser == PARSER_ABORT_PROBE
    )


def _as_string(b: List[UInt8]) raises -> String:
    """`b` as a String, or a NOT_UTF8 error when it is not UTF-8."""
    try:
        return String(StringSlice(from_utf8=Span(b)))
    except e:
        raise Error(String(NOT_UTF8) + ": the entry point takes a String: " + String(e))


def _is_ws(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


def _first_byte(b: List[UInt8]) -> Int:
    """The index of the first non-whitespace byte, or len(b)."""
    var i = 0
    while i < len(b) and _is_ws(b[i]):
        i += 1
    return i


def _string_end(b: List[UInt8], open: Int) -> Int:
    """The index of the `"` closing the string whose `"` is at `open`, or -1.
    A backslash skips the byte after it; nothing else is checked."""
    var i = open + 1
    while i < len(b):
        if b[i] == UInt8(ord("\\")):
            i += 2
            continue
        if b[i] == UInt8(ord('"')):
            return i
        i += 1
    return -1


def json_testee(b: List[UInt8]) raises:
    _ = parse_json_bytes(b)


def proto_codec_testee(b: List[UInt8]) raises:
    _ = decode_json[Value](_as_string(b))


def jsonl_testee(b: List[UInt8]) raises:
    var schema = infer_jsonl_schema(Span(b))
    var batch = materialize_jsonl_to_batch(Span(b), schema^)
    var rows = batch.num_rows()
    var i = _first_byte(b)
    if i >= len(b) or b[i] != UInt8(ord("{")):
        raise Error(
            String(MISREAD) + ": komira_jsonl returned " + String(rows)
            + " row(s) for a text whose top level is not an object, without an error"
        )
    if rows != 1:
        raise Error(
            String(MISREAD) + ": komira_jsonl returned " + String(rows)
            + " rows for a text whose top level is one object"
        )


def _first_key_path(b: List[UInt8]) -> List[String]:
    """The text's first key, when it starts `{"<key>"` and the key's bytes are
    UTF-8 with no escape; `a` otherwise. Found by a byte scan, so a malformed
    text has a path too."""
    var path = List[String]()
    var i = _first_byte(b)
    if i < len(b) and b[i] == UInt8(ord("{")):
        i += 1
        while i < len(b) and _is_ws(b[i]):
            i += 1
        if i < len(b) and b[i] == UInt8(ord('"')):
            var end = _string_end(b, i)
            if end > i:
                var key = List[UInt8]()
                var escaped = False
                for k in range(i + 1, end):
                    key.append(b[k])
                    if b[k] == UInt8(ord("\\")):
                        escaped = True
                if not escaped:
                    try:
                        path.append(String(StringSlice(from_utf8=Span(key))))
                        return path^
                    except:
                        pass
    path.append(String("a"))
    return path^


def json_index_testee(b: List[UInt8]) raises:
    # The column holds the file's bytes verbatim: no UTF-8 round trip.
    var rows = List[List[UInt8]]()
    rows.append(b.copy())
    var col = Column.from_string(StringArray.from_byte_lists(rows))
    _ = extract_column(col, _first_key_path(b), ArrowType.STRING, True)
    _ = extract_column(col, _first_key_path(b), ArrowType.STRING, False)
    var open = -1
    for i in range(len(b)):
        if b[i] == UInt8(ord('"')):
            open = i
            break
    if open >= 0:
        var end = _string_end(b, open)
        if end > open:
            try:
                _ = parse_string(Span(b), open + 1, end, True)
            except:
                pass  # crash-only: its own refusals are not a verdict here


# The errors the schema reader raises after its JSON parser accepted the
# whole text, while reading the parsed value as a schema (`_build_node` and
# the checks it calls). Any other error is a rejection.
def _avro_schema_errors() -> List[String]:
    return [
        "AvroSchemaError.MALFORMED_JSON: object missing 'type'",
        "AvroSchemaError.MALFORMED_JSON: record 'fields' not array",
        "AvroSchemaError.MALFORMED_JSON: field not object",
        "AvroSchemaError.MALFORMED_JSON: object-form union",
        "AvroSchemaError.MALFORMED_JSON: unexpected JSON value",
        "AvroSchemaError.UNKNOWN_TYPE",
        "AvroSchemaError.RECURSIVE_SCHEMA_NOT_SUPPORTED",
        "AvroSchemaError.FIXED_SIZE_OUT_OF_RANGE",
        "AvroSchemaError.DECIMAL_PRECISION_TOO_LARGE",
        "AvroSchemaError.LOGICAL_TYPE_PHYSICAL_MISMATCH",
    ]


def _append_avro_long(mut out: List[UInt8], v: Int):
    """An Avro `long` (zigzag varint) for a non-negative `v`."""
    var z = UInt64(v) << 1
    while z >= 0x80:
        out.append(UInt8((z & 0x7F) | 0x80))
        z >>= 7
    out.append(UInt8(z))


def ocf_header_around(b: List[UInt8]) -> List[UInt8]:
    """An Avro OCF header (spec: Object Container Files) whose one metadata
    entry is `avro.schema` with `b`, verbatim, as its value."""
    var out: List[UInt8] = [UInt8(ord("O")), UInt8(ord("b")), UInt8(ord("j")), 0x01]
    _append_avro_long(out, 1)  # one key/value pair follows
    var key = String("avro.schema")
    _append_avro_long(out, key.byte_length())
    out.extend(key.as_bytes())
    _append_avro_long(out, len(b))
    out.extend(Span(b))
    _append_avro_long(out, 0)  # the end of the map
    for _ in range(16):
        out.append(0)  # the sync marker
    return out^


def avro_testee(b: List[UInt8]) raises:
    var file = ocf_header_around(b)
    try:
        var header = decode_ocf_header(Span(file))
        _ = header.parse_schema()
    except e:
        var msg = String(e)
        for ref m in _avro_schema_errors():
            if msg.startswith(m):
                # Parsed as JSON; not an Avro schema: accepted at the JSON level.
                return
        raise e^


def log_query_testee(b: List[UInt8]) raises:
    if not is_json_object_text(_as_string(b)):
        raise Error("is_json_object_text: not exactly one well-formed JSON object")


def kci_logs_testee(b: List[UInt8]) raises:
    var s = String("")
    for i in range(len(b)):
        if b[i] == UInt8(ord('"')):
            _ = json_scan_string(Span(b), i, s)
            break
    try:
        var text = _as_string(b)
        _ = parse_get_log_events_body(text)
        _ = parse_entries_list_body(text, String("handle"))
        _ = parse_run_logs_body(text, String("run"))
    except:
        pass  # they never raise; NOT_UTF8 only skips them
    var end = json_skip_value(Span(b), 0)
    if end < 0:
        raise Error("json_skip_value: cannot skip a value at byte 0")
    var rest = json_skip_space(Span(b), end)
    if rest != len(b):
        raise Error("json_skip_value: byte " + String(rest) + " follows the value")


def connect_testee(b: List[UInt8]) raises:
    _ = parse_connect_error_json(Span(b))


def abort_probe_testee(b: List[UInt8]):
    """Aborts the process when `b` is `null` with only whitespace around it;
    returns (accepts) on anything else."""
    var lo = 0
    var hi = len(b)
    while lo < hi and _is_ws(b[lo]):
        lo += 1
    while hi > lo and _is_ws(b[hi - 1]):
        hi -= 1
    if hi - lo == 4 and b[lo] == 0x6E and b[lo + 1] == 0x75 and b[lo + 2] == 0x6C and b[lo + 3] == 0x6C:
        abort(ABORT_PROBE_TEXT)


def run_testee(parser: String, b: List[UInt8]) raises:
    """Run `parser`'s testee on `b`: returns on accept, raises on reject."""
    if parser == PARSER_JSON:
        json_testee(b)
    elif parser == PARSER_PROTO_CODEC:
        proto_codec_testee(b)
    elif parser == PARSER_JSONL:
        jsonl_testee(b)
    elif parser == PARSER_JSON_INDEX:
        json_index_testee(b)
    elif parser == PARSER_AVRO:
        avro_testee(b)
    elif parser == PARSER_LOG_QUERY:
        log_query_testee(b)
    elif parser == PARSER_KCI_LOGS:
        kci_logs_testee(b)
    elif parser == PARSER_CONNECT:
        connect_testee(b)
    elif parser == PARSER_ABORT_PROBE:
        abort_probe_testee(b)
    else:
        raise Error("no testee named '" + parser + "'")
