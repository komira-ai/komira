# =============================================================================
# QuoteStyle trait + 3 conformers — Csv[Q] dialect parameter.
# =============================================================================
#
# **WHY here (arrow), not the CSV package?** The `Csv[Q: QuoteStyle = Rfc4180]`
# parametric SerdeFormat marker lives at `arrow/formats.mojo` and
# parameterizes its `Q` over QuoteStyle. The dependency direction is
# CSV -> arrow, so QuoteStyle MUST live in arrow.
#
# Three conformers:
#   - Rfc4180 (DEFAULT): wrap-iff-trigger; doubled-quote escape `""`
#   - Excel:             always-quote-strings; BOM tolerance on read;
#                        formula-prefix opt-in on write; CR-only newlines
#   - Posix:             backslash-escape; `\"` for embedded quote
#
# Encapsulation: pure comptime constants — no UnsafePointer surface,
# no wildcard origins, no fields beyond a `_reserved: Bool` field-tag.
# =============================================================================


trait QuoteStyle(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """CSV quoting / escaping dialect.

    Each conformer exposes a fixed set of
    `comptime` flags + the `ESCAPE_BYTE` (zero when the dialect uses
    the RFC-4180 `""` doubled-quote escape; non-zero when the dialect
    uses a single-byte escape character, e.g. `\\` for Posix).

    Convention: `ESCAPE_BYTE == 0` is the sentinel for "no single-byte
    escape; RFC-4180 doubled-quote escape applies". Conformers with
    `DOUBLE_QUOTE_ESCAPES == True` set `ESCAPE_BYTE = 0`.

    Comptime:
        NAME:                  human-readable dialect identifier.
        ALWAYS_QUOTE_STRINGS:  write-side — wrap every STRING cell in quotes
                               (Excel convention; helps Excel auto-import).
        DOUBLE_QUOTE_ESCAPES:  read & write — `""` inside quoted region is
                               literal `"`. True for Rfc4180/Excel; False for Posix.
        ESCAPE_BYTE:           single-byte escape char when DOUBLE_QUOTE_ESCAPES
                               is False; 0 otherwise.
        ACCEPTS_BOM:           read-side — swallow UTF-8 BOM `0xEF 0xBB 0xBF`
                               at file start (Excel convention).
        FORMULA_PREFIX_QUOTE:  write-side — prefix `=` / `+` / `-` / `@` cells
                               with a quote to inhibit Excel formula injection.
        ACCEPT_CR_NEWLINES:    read-side — bare CR (no LF) terminates a row.
    """

    comptime NAME: StaticString
    comptime ALWAYS_QUOTE_STRINGS: Bool
    comptime DOUBLE_QUOTE_ESCAPES: Bool
    comptime ESCAPE_BYTE: UInt8
    comptime ACCEPTS_BOM: Bool
    comptime FORMULA_PREFIX_QUOTE: Bool
    comptime ACCEPT_CR_NEWLINES: Bool


# =============================================================================
# Rfc4180 — RFC-4180 strict CSV dialect (DEFAULT).
# =============================================================================


@fieldwise_init
struct Rfc4180(QuoteStyle):
    """RFC-4180 strict CSV dialect. Default for `Csv[Q]` and `ctx.read_csv`.

    Wire shape:
        - quoted region: starts on `"`; ends on next `"` (unless that `"` is
          followed by another `"`, in which case the pair is a literal `"`
          inside the field).
        - newlines: CRLF or LF (treats bare CR as a parser error in strict
          mode, or as a field byte in non-strict mode).
    """

    var _reserved: Bool

    def __init__(out self):
        self._reserved = False

    comptime NAME = StaticString("rfc4180")
    comptime ALWAYS_QUOTE_STRINGS = False
    comptime DOUBLE_QUOTE_ESCAPES = True
    comptime ESCAPE_BYTE = UInt8(0)
    comptime ACCEPTS_BOM = False
    comptime FORMULA_PREFIX_QUOTE = False
    comptime ACCEPT_CR_NEWLINES = False


# =============================================================================
# Excel — Microsoft Excel CSV dialect.
# =============================================================================


@fieldwise_init
struct Excel(QuoteStyle):
    """Excel CSV dialect. Microsoft conventions on top of RFC-4180.

    Differences from Rfc4180:
      - ALWAYS_QUOTE_STRINGS=True
      - ACCEPTS_BOM=True
      - FORMULA_PREFIX_QUOTE=True
      - ACCEPT_CR_NEWLINES=True
    """

    var _reserved: Bool

    def __init__(out self):
        self._reserved = False

    comptime NAME = StaticString("excel")
    comptime ALWAYS_QUOTE_STRINGS = True
    comptime DOUBLE_QUOTE_ESCAPES = True
    comptime ESCAPE_BYTE = UInt8(0)
    comptime ACCEPTS_BOM = True
    comptime FORMULA_PREFIX_QUOTE = True
    comptime ACCEPT_CR_NEWLINES = True


# =============================================================================
# Posix — Unix-tooling CSV dialect with backslash escapes.
# =============================================================================


@fieldwise_init
struct Posix(QuoteStyle):
    """Posix CSV dialect. Backslash-escape convention.

    Differences from Rfc4180:
      - DOUBLE_QUOTE_ESCAPES=False
      - ESCAPE_BYTE=ord('\\\\') = 0x5C
      - Newlines: LF only (Posix convention).
    """

    var _reserved: Bool

    def __init__(out self):
        self._reserved = False

    comptime NAME = StaticString("posix")
    comptime ALWAYS_QUOTE_STRINGS = False
    comptime DOUBLE_QUOTE_ESCAPES = False
    comptime ESCAPE_BYTE = UInt8(0x5C)  # '\\'
    comptime ACCEPTS_BOM = False
    comptime FORMULA_PREFIX_QUOTE = False
    comptime ACCEPT_CR_NEWLINES = False
