# =============================================================================
# CsvSink quoting: the exact output text (komira-ai/komira#449).
# =============================================================================
#
# RFC 4180 says a field is enclosed in quotes when it contains the delimiter,
# the quote, CR or LF, and an embedded quote is doubled. Until this test only
# the cross-format round trip noticed a missing trigger, and only for the
# values its dataset happened to hold. These cases pin the bytes CsvSink writes
# for each trigger, in the header (`_write_string_cell`) and in data cells
# (`_write_string_cell_to_bytes`, the packed path every batch takes), with the
# default comma and with a tab delimiter (the trigger is the CONFIGURED
# delimiter, so a comma in a tab-separated file stays bare).
#
# Mutants that turn this red, one per trigger: drop the delimiter, quote, `\n`
# or `\r` test from `_needs_quoting_bytes` (data rows) or `_needs_quoting`
# (header); write `s` instead of `s.replace(quote, quote + quote)` (no
# doubling).
# =============================================================================

from std.io import FileHandle
from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_csv.csv_sink import CsvSink
from komira_runtime_paths import test_tmpdir


def _batch(
    name0: String,
    var col0: List[String],
    name1: String,
    var col1: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.STRING, True))
    sb.add_field(Field(name1, ArrowType.STRING, True))
    var schema = sb.build()
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(Column.from_string(StringArray.from_strings(col0)))
    b.add_column(Column.from_string(StringArray.from_strings(col1)))
    return b.build(schema^)


def _write_and_read(var sink: CsvSink, var rb: RecordBatch) raises -> String:
    var path = sink.path
    sink.init_sink(rb.schema.copy())
    sink.accept_batch(rb^)
    sink.finish()
    var f = FileHandle(path, "r")
    var text = f.read()
    f.close()
    return text^


def test_comma_delimiter_every_trigger() raises:
    var k = List[String]()
    var v = List[String]()
    k.append(String("delim"))
    v.append(String("a,b"))
    k.append(String("lead"))
    v.append(String('"lead'))
    k.append(String("mid"))
    v.append(String('mid"q'))
    k.append(String("lf"))
    v.append(String("x\ny"))
    k.append(String("cr"))
    v.append(String("x\ry"))
    k.append(String("crlf"))
    v.append(String("x\r\ny"))
    k.append(String("plain"))
    v.append(String("plain\ttab"))
    var rb = _batch(String("k"), k^, String("v,w"), v^)
    var text = _write_and_read(
        CsvSink(test_tmpdir() + "/sink_quoting_comma.csv"), rb^
    )
    var want = String(
        'k,"v,w"\n'
        'delim,"a,b"\n'
        'lead,"""lead"\n'
        'mid,"mid""q"\n'
        'lf,"x\ny"\n'
        'cr,"x\ry"\n'
        'crlf,"x\r\ny"\n'
        "plain,plain\ttab\n"
    )
    assert_equal(text, want)


def test_tab_delimiter_quotes_tab_not_comma() raises:
    var k = List[String]()
    var v = List[String]()
    k.append(String("tab"))
    v.append(String("a\tb"))
    k.append(String("comma"))
    v.append(String("a,b"))
    k.append(String("quote"))
    v.append(String('say "x"'))
    var rb = _batch(String("k"), k^, String("v\tw"), v^)
    var text = _write_and_read(
        CsvSink(test_tmpdir() + "/sink_quoting_tab.tsv", delimiter="\t"), rb^
    )
    var want = String(
        'k\t"v\tw"\n'
        'tab\t"a\tb"\n'
        "comma\ta,b\n"
        'quote\t"say ""x"""\n'
    )
    assert_equal(text, want)


def main() raises:
    test_comma_delimiter_every_trigger()
    test_tab_delimiter_quotes_tab_not_comma()
    print("test_csv_sink_quoting: 2/2 PASS")
