# =============================================================================
# csv/csv_write_dialect.mojo -- the CSV options of `COPY ... TO`
# =============================================================================
#
# `CsvWriteDialect` is what `COPY ... TO '<file>.csv' (...)` says about the
# bytes of the file: the delimiter, the quote and escape characters, the text
# of a NULL, whether a header line is written, and the DATEFORMAT and
# TIMESTAMPFORMAT a date or timestamp cell is written with. The defaults are
# DuckDB's: `,`, `"`, `"`, the empty string, a header, no formats.
# `make_csv_write_dialect` builds one from the option values a COPY spells and
# refuses the ones DuckDB refuses, with DuckDB's reason, in DuckDB's order:
#
#   1. DELIMITER longer than 4 bytes (after `\t` is read as a tab, as DuckDB
#      reads it), then QUOTE or ESCAPE longer than 1 byte.
#   2. QUOTE in DELIMITER, then ESCAPE in DELIMITER.
#   3. A non-empty NULL holding DELIMITER, QUOTE or ESCAPE (or held by it), in
#      that order.
#
# Each is `CSV_DIALECT_INVALID`. Two delimiters DuckDB accepts and writes
# unreadably are `CSV_DIALECT_UNSUPPORTED` instead: an empty one (DuckDB puts
# nothing between the cells) and one of 2 to 4 bytes (DuckDB writes only the
# first byte between cells). An empty QUOTE means no cell is ever quoted and an
# empty ESCAPE that nothing is escaped, as in DuckDB.
#
# A cell is written by `csv_field`, DuckDB's rule: it is quoted when a quote
# character is set and the text equals the NULL text or holds the delimiter,
# the quote, `\n` or `\r`; inside the quotes each escape character and each
# quote is preceded by the escape character (with the default `"` for both, a
# quote is doubled). DATEFORMAT and TIMESTAMPFORMAT are kept as written: the
# writer parses each with `csv_temporal_format.TemporalFormat` only when the
# result has a column it applies to, as DuckDB does, so a format no column uses
# is never refused.

comptime CSV_DIALECT_INVALID = "CSV_DIALECT_INVALID"
"""Refusal: a CSV option value DuckDB refuses too (the message carries
DuckDB's reason)."""

comptime CSV_DIALECT_UNSUPPORTED = "CSV_DIALECT_UNSUPPORTED"
"""Refusal: a CSV option value DuckDB accepts and writes a file of that this
writer does not write (the message says what DuckDB would write)."""

comptime _NEWLINE: UInt8 = 0x0A
comptime _RETURN: UInt8 = 0x0D


struct CsvWriteDialect(Copyable, Movable):
    """The CSV options of a COPY: how its cells are separated, quoted and
    escaped, how a NULL reads, whether the header line is written, and the
    formats of dates and timestamps.

    Fields:
        delimiter:        the byte between two cells.
        quote:            the byte a cell is quoted with, or none (QUOTE '').
        escape:           the byte put before a quote or an escape inside a
                          quoted cell, or none (ESCAPE '').
        null_text:        the text of a NULL cell.
        header:           whether the first line holds the column names.
        date_format:      DATEFORMAT as written, or none.
        timestamp_format: TIMESTAMPFORMAT as written, or none.
    """

    var delimiter: UInt8
    var quote: Optional[UInt8]
    var escape: Optional[UInt8]
    var null_text: String
    var header: Bool
    var date_format: Optional[String]
    var timestamp_format: Optional[String]

    def __init__(out self):
        """DuckDB's defaults: `,`, `"`, `"`, NULL as nothing, a header, no
        formats."""
        self.delimiter = 0x2C
        self.quote = Optional[UInt8](0x22)
        self.escape = Optional[UInt8](0x22)
        self.null_text = String("")
        self.header = True
        self.date_format = Optional[String]()
        self.timestamp_format = Optional[String]()


def _shown(name: String, value: String) -> String:
    """`NAME 'value'`, the option as a COPY spells it, for a message."""
    return name + " '" + value.replace("'", "''") + "'"


def _invalid(option: String, reason: String) -> Error:
    return Error(
        String(CSV_DIALECT_INVALID) + ": COPY ... (" + option + "): " + reason
    )


def _single_byte(
    name: String, value: Optional[String], default: UInt8
) raises -> Optional[UInt8]:
    """The byte of QUOTE or ESCAPE: `default` when it is not given, none when
    it is empty, its one byte otherwise."""
    if not value:
        return Optional[UInt8](default)
    var b = value.value().as_bytes()
    if len(b) == 0:
        return Optional[UInt8]()
    if len(b) > 1:
        raise _invalid(
            _shown(name, value.value()),
            "the " + name.lower() + " option cannot exceed a size of 1 byte,"
            " as DuckDB refuses it",
        )
    return Optional[UInt8](b[0])


def _holds(text: String, b: UInt8) -> Bool:
    var s = text.as_bytes()
    for i in range(len(s)):
        if s[i] == b:
            return True
    return False


def make_csv_write_dialect(
    delimiter: Optional[String],
    quote: Optional[String],
    escape: Optional[String],
    null_text: Optional[String],
    header: Bool,
    date_format: Optional[String],
    timestamp_format: Optional[String],
) raises -> CsvWriteDialect:
    """The dialect of the option values a COPY gives (none for an option it
    leaves out), checked as DuckDB checks them (the module header lists the
    checks and their order).

    Raises:
        `CSV_DIALECT_INVALID` naming the option and DuckDB's reason for a
        value DuckDB refuses; `CSV_DIALECT_UNSUPPORTED` for an empty delimiter
        or one longer than a byte.
    """
    var d = CsvWriteDialect()
    d.header = header
    d.date_format = date_format.copy()
    d.timestamp_format = timestamp_format.copy()
    var delim_shown = String("DELIMITER ','")
    if delimiter:
        var raw = delimiter.value()
        delim_shown = _shown("DELIMITER", raw)
        var delim = raw.replace("\\t", "\t")
        var n = delim.byte_length()
        if n > 4:
            raise _invalid(
                delim_shown,
                "the delimiter option cannot exceed a size of 4 bytes, as"
                " DuckDB refuses it",
            )
        if n == 0:
            raise Error(
                String(CSV_DIALECT_UNSUPPORTED) + ": COPY ... (" + delim_shown
                + "): an empty delimiter; DuckDB writes the cells with"
                " nothing between them"
            )
        if n > 1:
            raise Error(
                String(CSV_DIALECT_UNSUPPORTED) + ": COPY ... (" + delim_shown
                + "): a delimiter of " + String(n) + " bytes; DuckDB writes"
                " only its first byte between the cells, so the delimiter is"
                " one byte"
            )
        d.delimiter = delim.as_bytes()[0]
    d.quote = _single_byte("QUOTE", quote, 0x22)
    d.escape = _single_byte("ESCAPE", escape, 0x22)
    if d.quote and d.quote.value() == d.delimiter:
        raise _invalid(
            delim_shown,
            "QUOTE must not appear in the DELIMITER specification and vice"
            " versa",
        )
    if d.escape and d.escape.value() == d.delimiter:
        raise _invalid(
            delim_shown,
            "ESCAPE must not appear in the DELIMITER specification and vice"
            " versa",
        )
    if null_text:
        d.null_text = null_text.value()
    if d.null_text.byte_length() > 0:
        var shown = _shown("NULL", d.null_text)
        if _holds(d.null_text, d.delimiter):
            raise _invalid(
                shown,
                "DELIMITER must not appear in the NULL specification and vice"
                " versa",
            )
        if d.quote and _holds(d.null_text, d.quote.value()):
            raise _invalid(
                shown,
                "QUOTE must not appear in the NULL specification and vice"
                " versa",
            )
        if d.escape and _holds(d.null_text, d.escape.value()):
            raise _invalid(
                shown,
                "ESCAPE must not appear in the NULL specification and vice"
                " versa",
            )
    return d^


def csv_field(text: String, dialect: CsvWriteDialect) -> List[UInt8]:
    """`text` as a cell of a file in `dialect`: quoted and escaped by DuckDB's
    rule (the module header says how), or as it is."""
    var out = List[UInt8](capacity=text.byte_length() + 2)
    csv_field_into(out, text, dialect)
    return out^


def csv_field_into(mut out: List[UInt8], text: String, dialect: CsvWriteDialect):
    """Append `csv_field(text, dialect)` to `out`."""
    var src = text.as_bytes()
    if not dialect.quote:
        out.extend(src)
        return
    var q = dialect.quote.value()
    var needs = text == dialect.null_text
    if not needs:
        for i in range(len(src)):
            var b = src[i]
            if b == dialect.delimiter or b == q or b == _NEWLINE or b == _RETURN:
                needs = True
                break
    if not needs:
        out.extend(src)
        return
    out.append(q)
    for i in range(len(src)):
        var b = src[i]
        if dialect.escape and (b == dialect.escape.value() or b == q):
            out.append(dialect.escape.value())
        out.append(b)
    out.append(q)
