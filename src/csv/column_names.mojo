"""The names a CSV reader gives the columns of a file with no header line."""


def header_free_column_name(index: Int, count: Int) -> String:
    """The name of column `index` (zero-based) of `count` columns read
    without a header line, as DuckDB's read_csv names it: `column` then the
    index, padded with leading zeros to the digit count of the last index
    (`column0` .. `column9` for ten columns, `column00` .. `column10` for
    eleven). `count` is at least 1 and `index` below it."""
    var digits = String(index)
    var width = String(count - 1).byte_length()
    var out = String("column")
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out^
