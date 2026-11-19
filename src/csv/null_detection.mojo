# =============================================================================
# null_detection — pandas-parity multi-string null detection.
# =============================================================================
#
# Tests whether a cell byte-span matches any of the configured null tokens.
# The token set lives in `CsvReadOptions.null_strings` (InlineArray[String, 8]
# + `_n_null_strings: Int` counter — no pointer fields).
#
# Default tokens: `["", "NULL", "NA", "NaN", "null"]` (pandas-parity).
# =============================================================================

from .csv_options import CsvReadOptions, MAX_NULL_STRINGS


@always_inline
def _bytes_equal(a: Span[UInt8, _], b_str: String) -> Bool:
    """Compare a byte-span against a String's bytes for exact equality."""
    var b = b_str.as_bytes()
    if len(a) != len(b):
        return False
    var i = 0
    while i < len(a):
        if a[i] != b[i]:
            return False
        i = i + 1
    return True


def is_null_cell(cell: Span[UInt8, _], options: CsvReadOptions) -> Bool:
    """True iff `cell` byte-span matches any configured null token.

    Strict mode: `options._n_null_strings == 0` -> NO cells are null
    (every cell coerces; empty cells are typed parse failures).

    Args:
        cell: Cell byte-span (inclusive of any whitespace; the FSA does
            NOT trim).
        options: CsvReadOptions carrying the null-token set.

    Returns:
        True iff `cell` exactly matches one of `options.null_strings[0..n)`.
    """
    var n = options._n_null_strings
    if n == 0:
        return False
    var i = 0
    while i < n:
        if _bytes_equal(cell, options.null_strings[i]):
            return True
        i = i + 1
    return False


def is_true_cell(cell: Span[UInt8, _], options: CsvReadOptions) -> Bool:
    """True iff `cell` byte-span matches any configured true-token.

    Default true-set: `["true", "TRUE", "T", "1", "yes", "Y"]`.
    """
    var n = options._n_true_strings
    var i = 0
    while i < n:
        if _bytes_equal(cell, options.true_strings[i]):
            return True
        i = i + 1
    return False


def is_false_cell(cell: Span[UInt8, _], options: CsvReadOptions) -> Bool:
    """True iff `cell` byte-span matches any configured false-token.

    Default false-set: `["false", "FALSE", "F", "0", "no", "N"]`.
    """
    var n = options._n_false_strings
    var i = 0
    while i < n:
        if _bytes_equal(cell, options.false_strings[i]):
            return True
        i = i + 1
    return False
