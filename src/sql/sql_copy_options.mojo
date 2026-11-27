# =============================================================================
# sql/sql_copy_options.mojo -- the option list of `COPY ... TO '<path>' (...)`
# =============================================================================
#
# The parser reads each `<name> <value>` of the list and hands it to
# `CopyOptions.add`; once the list is closed, `CopyOptions.finish` validates
# them together and answers the `CopyTarget`: the format, the compression and
# the CSV dialect of the file. TWO PASSES, deliberately: the meaning of HEADER,
# ARRAY, COMPRESSION_LEVEL and the CSV options depends on the FORMAT, and
# DuckDB does not require FORMAT to come first, so `(HEADER false, FORMAT csv)`
# means what `(FORMAT csv, HEADER false)` means.
#
# The options (the subset DuckDB's COPY ... TO takes that this engine writes):
#
#   FORMAT <parquet|csv|json>         quoted or bare, any case
#   COMPRESSION | CODEC <codec>
#   COMPRESSION_LEVEL <int>
#   HEADER <true|false>               csv
#   ARRAY <true|false>                json
#   DELIMITER | DELIM | SEP '<s>'     csv
#   QUOTE '<s>'   ESCAPE '<s>'        csv
#   NULL | NULLSTR '<s>'              csv
#   DATEFORMAT | DATE_FORMAT '<s>'    csv
#   TIMESTAMPFORMAT | TIMESTAMP_FORMAT '<s>'   csv
#
# The CSV options are checked by `csv.csv_write_dialect.make_csv_write_dialect`
# as DuckDB checks them. Their values are case-sensitive, so they are taken
# from a quoted string only: a bare word reaches the parser lower-folded and
# is refused, as is a number (DuckDB refuses one too).
#
# AN OPTION IS NEVER ACCEPTED AND IGNORED: an ignored option writes a file that
# is not what the SQL asked for, and no row count shows it. So every refusal
# below names the option: an unknown one; one given twice, or under two of its
# spellings; a CSV option on another format; `ARRAY true` (the JSON writer
# writes one object per line, DuckDB's ARRAY false); a COMPRESSION_LEVEL other
# than the one the writer uses for the codec.

from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_LZ4,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_CSV,
    WFMT_JSONL,
    WFMT_PARQUET,
    write_codec_name,
    write_format_name,
    write_target_supported,
)
from csv.csv_write_dialect import CsvWriteDialect, make_csv_write_dialect

from .sql_copy_format import copy_codec_from_path, copy_format_from_path

comptime COPY_VALUE_STRING: UInt8 = 0
"""A quoted option value, as written."""
comptime COPY_VALUE_WORD: UInt8 = 1
"""A bare option value, lower-folded by the tokenizer."""
comptime COPY_VALUE_INT: UInt8 = 2
"""An integer option value."""

comptime _OPTION_LIST = (
    "FORMAT / COMPRESSION / COMPRESSION_LEVEL / HEADER / ARRAY / DELIMITER /"
    " QUOTE / ESCAPE / NULL / DATEFORMAT / TIMESTAMPFORMAT"
)
"""The options this engine takes, for a message."""


def copy_option_list() -> String:
    """The COPY options this engine takes, for a message."""
    return String(_OPTION_LIST)


struct CopyOptionValue(Copyable, Movable):
    """One option value as the parser read it.

    Fields:
        kind:    COPY_VALUE_STRING, COPY_VALUE_WORD or COPY_VALUE_INT.
        text:    the string or the word ("" for an integer).
        int_val: the integer (0 otherwise).
    """

    var kind: UInt8
    var text: String
    var int_val: Int

    def __init__(out self, kind: UInt8, text: String, int_val: Int):
        self.kind = kind
        self.text = text
        self.int_val = int_val


struct CopyTarget(Movable):
    """What a COPY's options say about its file.

    Fields:
        fmt:   the WFMT_* format.
        codec: the WCOMP_* compression.
        csv:   the CSV dialect (DuckDB's defaults for another format).
    """

    var fmt: UInt8
    var codec: UInt8
    var csv: CsvWriteDialect

    def __init__(out self, fmt: UInt8, codec: UInt8, var csv: CsvWriteDialect):
        self.fmt = fmt
        self.codec = codec
        self.csv = csv^


def _format_word(w: String) raises -> UInt8:
    """Map a COPY `FORMAT <word>` to a WFMT_* code (raises on a format with no
    wired sink). DuckDB spells newline-delimited JSON `FORMAT 'json'` +
    `ARRAY false`; `jsonl`/`ndjson` are accepted as the same thing because
    that is what the sink writes."""
    if w == "parquet":
        return WFMT_PARQUET
    if w == "csv":
        return WFMT_CSV
    if w == "json" or w == "jsonl" or w == "ndjson":
        return WFMT_JSONL
    raise Error(
        "SQL not supported: COPY ... (FORMAT '" + w + "') — wired write sinks are"
        " parquet / csv / json"
    )


def _codec_word(w: String) raises -> UInt8:
    """Map a COPY `COMPRESSION <word>` to a WCOMP_* code (raises on an unknown
    codec). Whether the codec is legal for the chosen FORMAT is a SEPARATE
    check (`write_target_supported`): snappy is a Parquet page codec and has
    no whole-file CSV/JSONL arm."""
    if w == "uncompressed" or w == "none":
        return WCOMP_UNCOMPRESSED
    if w == "snappy":
        return WCOMP_SNAPPY
    if w == "zstd":
        return WCOMP_ZSTD
    if w == "gzip" or w == "gz":
        return WCOMP_GZIP
    # `lz4_raw` is the Parquet codec id 7 spelling; `lz4` is what DuckDB's CSV /
    # JSONL COPY calls the same whole-file wrapper. One WCOMP code, because the
    # sink arm each one resolves to is chosen by the FORMAT.
    if w == "lz4" or w == "lz4_raw":
        return WCOMP_LZ4
    raise Error(
        "SQL not supported: COPY compression '" + w + "' (uncompressed / snappy /"
        " zstd / gzip / lz4_raw)"
    )


def _codec_fixed_level(codec: UInt8) -> Int:
    """The compression LEVEL the wired sink for `codec` is parameterized on, or
    -1 for a codec that takes no level. `COMPRESSION_LEVEL` is honoured only by
    AGREEING with it."""
    if codec == WCOMP_ZSTD:
        return 3      # WholeFileCompressed[..., Zstd[3]] / Parquet[Zstd[3]]
    if codec == WCOMP_GZIP:
        return 6      # Gzip[6] — zlib's default level
    return -1


def _canonical(name: String) -> String:
    """The option a spelling names, upper-case (`SEP` -> `DELIMITER`), or ""
    for a name that is not a COPY option."""
    if name == "format":
        return "FORMAT"
    if name == "compression" or name == "codec":
        return "COMPRESSION"
    if name == "compression_level":
        return "COMPRESSION_LEVEL"
    if name == "header":
        return "HEADER"
    if name == "array":
        return "ARRAY"
    if name == "delimiter" or name == "delim" or name == "sep":
        return "DELIMITER"
    if name == "quote":
        return "QUOTE"
    if name == "escape":
        return "ESCAPE"
    if name == "null" or name == "nullstr":
        return "NULL"
    if name == "dateformat" or name == "date_format":
        return "DATEFORMAT"
    if name == "timestampformat" or name == "timestamp_format":
        return "TIMESTAMPFORMAT"
    return ""


def _word(v: CopyOptionValue) raises -> String:
    """A word-valued option: a quoted value lower-folded, or a bare word."""
    if v.kind == COPY_VALUE_STRING:
        return v.text.lower()
    if v.kind == COPY_VALUE_WORD:
        return v.text
    raise Error("SQL syntax error: expected a COPY option value")


def _bool(opt: String, v: CopyOptionValue) raises -> Bool:
    """A BOOLEAN option (`HEADER true` / `ARRAY false`), in the bare and the
    quoted spellings DuckDB accepts."""
    var w = _word(v)
    if w == "true" or w == "1" or w == "on":
        return True
    if w == "false" or w == "0" or w == "off":
        return False
    raise Error(
        "SQL syntax error: COPY option " + opt + " expects true/false, got '"
        + w + "'"
    )


def _string(opt: String, v: CopyOptionValue) raises -> String:
    """A string-valued CSV option: a quoted string, as written."""
    if v.kind == COPY_VALUE_STRING:
        return v.text
    if v.kind == COPY_VALUE_WORD:
        raise Error(
            "SQL not supported: COPY option " + opt + " " + v.text
            + " — write the value quoted (" + opt + " '...'); a bare word is"
            " read lower-cased, which is not the text DuckDB would write"
        )
    raise Error(
        "SQL bind error: COPY option " + opt + " expects a VARCHAR, not the"
        " integer " + String(v.int_val) + " (DuckDB refuses it too)"
    )


struct CopyOptions(Movable):
    """The options of one COPY, collected (`add`) before they are validated
    together (`finish`)."""

    var _seen: List[String]
    var _spelled: List[String]
    var fmt_word: Optional[String]
    var codec_word: Optional[String]
    var level: Optional[Int]
    var header: Optional[Bool]
    var array: Optional[Bool]
    var delimiter: Optional[String]
    var quote: Optional[String]
    var escape: Optional[String]
    var null_text: Optional[String]
    var date_format: Optional[String]
    var timestamp_format: Optional[String]

    def __init__(out self):
        self._seen = List[String]()
        self._spelled = List[String]()
        self.fmt_word = Optional[String]()
        self.codec_word = Optional[String]()
        self.level = Optional[Int]()
        self.header = Optional[Bool]()
        self.array = Optional[Bool]()
        self.delimiter = Optional[String]()
        self.quote = Optional[String]()
        self.escape = Optional[String]()
        self.null_text = Optional[String]()
        self.date_format = Optional[String]()
        self.timestamp_format = Optional[String]()

    def add(mut self, name: String, value: CopyOptionValue) raises:
        """Record the option `name` (as the tokenizer gives it, lower-folded)
        with `value`.

        Raises:
            an unknown option, by name; an option given twice or under two of
            its spellings; a value of the wrong kind.
        """
        var opt = _canonical(name)
        if opt == "":
            raise Error(
                "SQL not supported: COPY option '" + name + "' ("
                + String(_OPTION_LIST) + ")"
            )
        for i in range(len(self._seen)):
            if self._seen[i] == opt:
                raise Error(
                    "SQL syntax error: COPY option " + name.upper()
                    + " repeats " + self._spelled[i].upper()
                    + "; give each option once"
                )
        self._seen.append(opt)
        self._spelled.append(name)
        if opt == "FORMAT":
            self.fmt_word = _word(value)
        elif opt == "COMPRESSION":
            self.codec_word = _word(value)
        elif opt == "COMPRESSION_LEVEL":
            if value.kind != COPY_VALUE_INT:
                raise Error(
                    "SQL syntax error: expected an integer COPY option value"
                )
            self.level = value.int_val
        elif opt == "HEADER":
            self.header = _bool(String("HEADER"), value)
        elif opt == "ARRAY":
            self.array = _bool(String("ARRAY"), value)
        elif opt == "DELIMITER":
            self.delimiter = _string(opt, value)
        elif opt == "QUOTE":
            self.quote = _string(opt, value)
        elif opt == "ESCAPE":
            self.escape = _string(opt, value)
        elif opt == "NULL":
            self.null_text = _string(opt, value)
        elif opt == "DATEFORMAT":
            self.date_format = _string(opt, value)
        else:
            self.timestamp_format = _string(opt, value)

    def finish(self, dest: String) raises -> CopyTarget:
        """Validate the options, now that FORMAT is known, against the
        destination `dest`: with no FORMAT the format comes from its
        extension, and with no COMPRESSION the codec from the format and
        `dest` (`sql_copy_format`)."""
        var fmt: UInt8
        if self.fmt_word:
            fmt = _format_word(self.fmt_word.value())
        else:
            fmt = copy_format_from_path(dest)
        var codec = copy_codec_from_path(fmt, dest)
        if self.codec_word:
            codec = _codec_word(self.codec_word.value())
        if not write_target_supported(fmt, codec):
            raise Error(
                "SQL not supported: COPY ... (FORMAT '" + write_format_name(fmt)
                + "', COMPRESSION '" + write_codec_name(codec)
                + "') — no wired write sink for that pair"
            )
        if fmt != WFMT_CSV:
            for i in range(len(self._seen)):
                self._refuse_csv_option(self._seen[i], fmt)
        if self.array:
            if fmt != WFMT_JSONL:
                raise Error(
                    "SQL not supported: COPY option ARRAY applies to FORMAT 'json',"
                    " not '" + write_format_name(fmt) + "'"
                )
            if self.array.value():
                raise Error(
                    "SQL not supported: COPY ... (ARRAY true) — the JSONL sink"
                    " writes newline-delimited objects (DuckDB's ARRAY false); it"
                    " cannot emit a single JSON array"
                )
        if self.level:
            var level = self.level.value()
            var want = _codec_fixed_level(codec)
            if want < 0:
                raise Error(
                    "SQL not supported: COPY ... (COMPRESSION_LEVEL "
                    + String(level) + ") — codec '" + write_codec_name(codec)
                    + "' takes no level"
                )
            if level != want:
                raise Error(
                    "SQL not supported: COPY ... (COMPRESSION '"
                    + write_codec_name(codec) + "', COMPRESSION_LEVEL "
                    + String(level) + ") — the wired sink is parameterized on"
                    " level " + String(want) + "; writing a different level"
                    " silently would not be the file the SQL asked for"
                )
        if fmt != WFMT_CSV:
            return CopyTarget(fmt, codec, CsvWriteDialect())
        var dialect = make_csv_write_dialect(
            self.delimiter,
            self.quote,
            self.escape,
            self.null_text,
            self.header.value() if self.header else True,
            self.date_format,
            self.timestamp_format,
        )
        return CopyTarget(fmt, codec, dialect^)

    def _refuse_csv_option(self, opt: String, fmt: UInt8) raises:
        """Refuse the CSV option `opt` on the format `fmt`, which is not CSV:
        DuckDB's JSON writer takes DATEFORMAT and TIMESTAMPFORMAT, and this
        one does not yet; every other CSV option is CSV's alone."""
        if (
            opt != "HEADER"
            and opt != "DELIMITER"
            and opt != "QUOTE"
            and opt != "ESCAPE"
            and opt != "NULL"
            and opt != "DATEFORMAT"
            and opt != "TIMESTAMPFORMAT"
        ):
            return
        if fmt == WFMT_JSONL and (opt == "DATEFORMAT" or opt == "TIMESTAMPFORMAT"):
            raise Error(
                "SQL not supported: COPY ... (FORMAT 'json', " + opt + ") — the"
                " JSON writer writes dates and timestamps in DuckDB's default"
                " text only"
            )
        raise Error(
            "SQL not supported: COPY option " + opt + " applies to FORMAT"
            " 'csv', not '" + write_format_name(fmt) + "'"
        )
