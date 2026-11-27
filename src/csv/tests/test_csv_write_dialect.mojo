# =============================================================================
# The CSV options of a COPY are checked and quote cells as DuckDB does
# =============================================================================
#
# Covers: `csv_write_dialect.make_csv_write_dialect` builds the dialect of a
# COPY's DELIMITER, QUOTE, ESCAPE, NULL, HEADER, DATEFORMAT and
# TIMESTAMPFORMAT and refuses what DuckDB refuses, with DuckDB's reason and in
# DuckDB's order; `csv_field` writes a cell as DuckDB's COPY does. Every
# expected text is what DuckDB's COPY ... TO wrote, or the reason it gave, for
# the same options.
#
# What each test proves:
#   * test_the_defaults: no option given is `,`, `"`, `"`, NULL as nothing,
#     a header and no formats, the same as `CsvWriteDialect()`.
#   * test_the_values_given: each value lands in its field; `\t` is a tab, as
#     DuckDB reads it; an empty QUOTE or ESCAPE is none; the formats are kept
#     as written.
#   * test_refused_values: a delimiter of more than 4 bytes, a QUOTE or
#     ESCAPE of more than one byte (also `\t`, which DuckDB reads as two
#     bytes there); QUOTE or ESCAPE equal to the delimiter (QUOTE first); a
#     NULL holding the delimiter, the quote or the escape (in that order, the
#     default escape `"` included), each by exact message; an empty
#     delimiter, one of 2 to 4 bytes (`ab`, `\t\t`, a two-byte `é`) refused
#     by name. Catches a value DuckDB refuses written anyway and a check made
#     in another order than DuckDB's.
#   * test_fields_quoted_as_duckdb_does: the default dialect quotes the empty
#     string and a cell holding `,`, `"`, `\n` or `\r` and doubles `"`;
#     DELIMITER ';' quotes `x;y` and not `x,y`; NULL 'NA' quotes `NA` and
#     not the empty string; QUOTE '|' (escape `"`) quotes `a|b` as `|a"|b|`
#     and leaves `q"r`; ESCAPE '\' escapes `"` and `\` inside quotes and
#     does not quote `a\b` for its `\`; QUOTE "'" ESCAPE '\' writes
#     `'it\'s\\x'`; an empty QUOTE never quotes; an empty ESCAPE leaves the
#     quote inside a quoted cell as it is. Catches the quote rule of one
#     dialect applied to another, an escape that triggers quoting, and the
#     escape character itself left unescaped.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from csv.csv_write_dialect import (
    CSV_DIALECT_INVALID,
    CSV_DIALECT_UNSUPPORTED,
    CsvWriteDialect,
    csv_field,
    make_csv_write_dialect,
)

def _s(v: String) -> Optional[String]:
    return Optional[String](v)


def _d(
    delimiter: Optional[String] = Optional[String](),
    quote: Optional[String] = Optional[String](),
    escape: Optional[String] = Optional[String](),
    null_text: Optional[String] = Optional[String](),
) raises -> CsvWriteDialect:
    return make_csv_write_dialect(
        delimiter, quote, escape, null_text, True, Optional[String](),
        Optional[String](),
    )


def _field(text: String, d: CsvWriteDialect) -> String:
    return String(unsafe_from_utf8=Span(csv_field(text, d)))


def _refused(
    delimiter: Optional[String],
    quote: Optional[String],
    escape: Optional[String],
    null_text: Optional[String],
    want: String,
) raises:
    try:
        _ = _d(delimiter, quote, escape, null_text)
    except e:
        assert_equal(String(e), want)
        return
    assert_true(False, "not refused: " + want)


def _assert_defaults(x: CsvWriteDialect) raises:
    assert_equal(Int(x.delimiter), 0x2C)
    assert_equal(Int(x.quote.value()), 0x22)
    assert_equal(Int(x.escape.value()), 0x22)
    assert_equal(x.null_text, "")
    assert_true(x.header)
    assert_false(Bool(x.date_format))
    assert_false(Bool(x.timestamp_format))


def test_the_defaults() raises:
    _assert_defaults(_d())
    _assert_defaults(CsvWriteDialect())


def test_the_values_given() raises:
    var d = make_csv_write_dialect(
        Optional[String](";"), Optional[String]("'"), Optional[String]("\\"),
        Optional[String]("NA"), False, Optional[String]("%d/%m/%Y"),
        Optional[String]("%c"),
    )
    assert_equal(Int(d.delimiter), 0x3B)
    assert_equal(Int(d.quote.value()), 0x27)
    assert_equal(Int(d.escape.value()), 0x5C)
    assert_equal(d.null_text, "NA")
    assert_false(d.header)
    assert_equal(d.date_format.value(), "%d/%m/%Y")
    assert_equal(d.timestamp_format.value(), "%c")
    assert_equal(Int(_d(Optional[String]("\\t")).delimiter), 0x09)
    assert_equal(Int(_d(Optional[String]("\t")).delimiter), 0x09)
    assert_false(Bool(_d(quote=Optional[String]("")).quote))
    assert_false(Bool(_d(escape=Optional[String]("")).escape))
    assert_equal(_d(null_text=Optional[String]("")).null_text, "")


def test_refused_values() raises:
    var inv = String(CSV_DIALECT_INVALID) + ": COPY ... ("
    var uns = String(CSV_DIALECT_UNSUPPORTED) + ": COPY ... ("
    _refused(_s("abcde"), Optional[String](), Optional[String](), Optional[String](), inv + "DELIMITER 'abcde'): the delimiter option cannot exceed a size of 4 bytes, as DuckDB refuses it")
    _refused(_s("abcde"), _s("xy"), Optional[String](), Optional[String](), inv + "DELIMITER 'abcde'): the delimiter option cannot exceed a size of 4 bytes, as DuckDB refuses it")
    _refused(Optional[String](), _s("xy"), Optional[String](), Optional[String](), inv + "QUOTE 'xy'): the quote option cannot exceed a size of 1 byte, as DuckDB refuses it")
    _refused(Optional[String](), _s("\\t"), Optional[String](), Optional[String](), inv + "QUOTE '\\t'): the quote option cannot exceed a size of 1 byte, as DuckDB refuses it")
    _refused(Optional[String](), _s("é"), Optional[String](), Optional[String](), inv + "QUOTE 'é'): the quote option cannot exceed a size of 1 byte, as DuckDB refuses it")
    _refused(Optional[String](), Optional[String](), _s("ab"), Optional[String](), inv + "ESCAPE 'ab'): the escape option cannot exceed a size of 1 byte, as DuckDB refuses it")
    _refused(_s('"'), Optional[String](), Optional[String](), Optional[String](), inv + "DELIMITER '\"'): QUOTE must not appear in the DELIMITER specification and vice versa")
    _refused(_s(";"), _s(";"), _s(";"), Optional[String](), inv + "DELIMITER ';'): QUOTE must not appear in the DELIMITER specification and vice versa")
    _refused(_s(";"), Optional[String](), _s(";"), Optional[String](), inv + "DELIMITER ';'): ESCAPE must not appear in the DELIMITER specification and vice versa")
    _refused(_s('"'), _s("|"), Optional[String](), Optional[String](), inv + "DELIMITER '\"'): ESCAPE must not appear in the DELIMITER specification and vice versa")
    _refused(Optional[String](), Optional[String](), Optional[String](), _s("a,b"), inv + "NULL 'a,b'): DELIMITER must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), Optional[String](), Optional[String](), _s(","), inv + "NULL ','): DELIMITER must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), _s("x"), Optional[String](), _s("xy"), inv + "NULL 'xy'): QUOTE must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), Optional[String](), Optional[String](), _s('"'), inv + "NULL '\"'): QUOTE must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), _s("|"), Optional[String](), _s('a"b'), inv + "NULL 'a\"b'): ESCAPE must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), Optional[String](), _s("N"), _s("NA"), inv + "NULL 'NA'): ESCAPE must not appear in the NULL specification and vice versa")
    _refused(Optional[String](), Optional[String](), Optional[String](), _s("it's,"), inv + "NULL 'it''s,'): DELIMITER must not appear in the NULL specification and vice versa")
    _refused(_s(""), Optional[String](), Optional[String](), Optional[String](), uns + "DELIMITER ''): an empty delimiter; DuckDB writes the cells with nothing between them")
    _refused(_s("ab"), Optional[String](), Optional[String](), Optional[String](), uns + "DELIMITER 'ab'): a delimiter of 2 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte")
    _refused(_s("\\t\\t"), Optional[String](), Optional[String](), Optional[String](), uns + "DELIMITER '\\t\\t'): a delimiter of 2 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte")
    _refused(_s("é"), Optional[String](), Optional[String](), Optional[String](), uns + "DELIMITER 'é'): a delimiter of 2 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte")
    _refused(_s("abcd"), Optional[String](), Optional[String](), Optional[String](), uns + "DELIMITER 'abcd'): a delimiter of 4 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte")
    # An empty QUOTE, ESCAPE or NULL is checked against nothing.
    _ = _d(_s('"'), _s(""), _s(""), Optional[String]())
    _ = _d(_s(";"), _s(""), _s(""), _s("x"))


def test_fields_quoted_as_duckdb_does() raises:
    var d = CsvWriteDialect()
    assert_equal(_field("plain", d), "plain")
    assert_equal(_field("", d), '""')
    assert_equal(_field("x,y", d), '"x,y"')
    assert_equal(_field('say "hi"', d), '"say ""hi"""')
    assert_equal(_field("l1\nl2", d), '"l1\nl2"')
    assert_equal(_field("a\rb", d), '"a\rb"')
    assert_equal(_field("x;y", d), "x;y")
    var semi = _d(_s(";"))
    assert_equal(_field("x;y", semi), '"x;y"')
    assert_equal(_field("x,y", semi), "x,y")
    assert_equal(_field("1.5", _d(_s("."))), '"1.5"')
    var na = _d(null_text=_s("NA"))
    assert_equal(_field("NA", na), '"NA"')
    assert_equal(_field("NAB", na), "NAB")
    assert_equal(_field("", na), "")
    var pipe = _d(quote=_s("|"))
    assert_equal(_field("a|b", pipe), '|a"|b|')
    assert_equal(_field('q"r', pipe), 'q"r')
    assert_equal(_field("c,d", pipe), "|c,d|")
    var bs = _d(escape=_s("\\"))
    assert_equal(_field('q"t', bs), '"q\\"t"')
    assert_equal(_field("a\\b", bs), "a\\b")
    assert_equal(_field('a"\\b', bs), '"a\\"\\\\b"')
    var sq = _d(quote=_s("'"), escape=_s("\\"))
    assert_equal(_field("it's\\x", sq), "'it\\'s\\\\x'")
    assert_equal(_field('q"t', sq), 'q"t')
    var noquote = _d(quote=_s(""))
    assert_equal(_field("a,b", noquote), "a,b")
    assert_equal(_field("", noquote), "")
    var noescape = _d(escape=_s(""))
    assert_equal(_field('q"', noescape), '"q""')
    assert_equal(_field("a,b", noescape), '"a,b"')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
