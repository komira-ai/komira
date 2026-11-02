# The declared type of a result column, in one vocabulary shared by both
# engines. DuckDB's `DESCRIBE <query>` names each column's type; the komira
# engine's result batches carry an Arrow type per column. Both are mapped onto
# the entries below, and two results agree on a column's declared type when the
# entries are the same text. The mapping is written down as a table in
# README.md ("Declared column types").
#
# The vocabulary: BOOLEAN, TINYINT, SMALLINT, INTEGER, BIGINT, HUGEINT,
# UTINYINT, USMALLINT, UINTEGER, UBIGINT, UHUGEINT, FLOAT, DOUBLE, VARCHAR,
# DATE, and DECIMAL(p,s) with 1 <= p <= 38 and 0 <= s <= p, written with no
# space and no leading zero. A type with no entry (TIMESTAMP, a nested type, an
# Arrow type this arm has no name for, a DECIMAL that DuckDB cannot have) is
# kept as `UNMAPPED(<the name it came with>)`. The comparison reports an
# unmapped type as a failure; it never passes, not even against itself.
#
# Two different entries are a failure, except for the pairs of the table of
# allowed departures at the end of this file (README.md, "Allowed departures"):
# the one place where the rule "the same result as DuckDB for the same SQL"
# gives way, and only for a limit of the Arrow representation.

comptime UNMAPPED_PREFIX: String = "UNMAPPED("


def unmapped_type(raw: String) -> String:
    """The entry for a type outside the vocabulary: `UNMAPPED(<raw>)`."""
    return String(UNMAPPED_PREFIX) + raw + String(")")


def is_unmapped(declared: String) -> Bool:
    """Whether `declared` is an `UNMAPPED(...)` entry."""
    return declared.startswith(String(UNMAPPED_PREFIX)) and declared.endswith(String(")"))


def _is_plain_name(name: String) -> Bool:
    for known in [
        "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "DOUBLE", "VARCHAR", "DATE",
    ]:
        if name == String(known):
            return True
    return False


def _number(digits: String) -> Int:
    """The value of 1 or 2 digits written with no leading zero, or -1."""
    var b = digits.as_bytes()
    if len(b) < 1 or len(b) > 2:
        return -1
    if len(b) == 2 and b[0] == UInt8(48):
        return -1
    var v = 0
    for c in b:
        if c < UInt8(48) or c > UInt8(57):
            return -1
        v = v * 10 + Int(c) - 48
    return v


def _is_decimal_type(name: String) -> Bool:
    if not name.startswith(String("DECIMAL(")) or not name.endswith(String(")")):
        return False
    var inner = String(name[byte=8 : name.byte_length() - 1])
    var comma = inner.find(String(","))
    if comma < 0:
        return False
    var p = _number(String(inner[byte=0:comma]))
    var s = _number(String(inner[byte = comma + 1 : inner.byte_length()]))
    return p >= 1 and p <= 38 and s >= 0 and s <= p


def is_declared_type(declared: String) -> Bool:
    """Whether `declared` is an entry of the vocabulary (an `UNMAPPED(...)`
    entry is not)."""
    return _is_plain_name(declared) or _is_decimal_type(declared)


def decimal_type(precision: Int, scale: Int) -> String:
    """`DECIMAL(precision,scale)` when that is in the vocabulary, else the
    unmapped entry for it."""
    var name = String("DECIMAL(") + String(precision) + String(",") + String(scale) + String(")")
    if _is_decimal_type(name):
        return name^
    return unmapped_type(name)


def duckdb_declared_type(raw: String) -> String:
    """The entry for a column type as DuckDB's `DESCRIBE` names it (upper case,
    `DECIMAL(38,4)` with no space): the same text when it is in the
    vocabulary, `UNMAPPED(<raw>)` otherwise."""
    if is_declared_type(raw):
        return raw.copy()
    return unmapped_type(raw)


struct AllowedDeparture(Copyable, Movable):
    """One allowed departure: DuckDB's `duckdb` type and the komira engine's
    `komira` type (both entries of the vocabulary) are accepted as the same
    column when the values are exactly equal; the cell is then labelled
    DEPARTURE with `reason`."""

    var duckdb: String
    var komira: String
    var reason: String

    def __init__(out self, var duckdb: String, var komira: String, var reason: String):
        self.duckdb = duckdb^
        self.komira = komira^
        self.reason = reason^


def allowed_departures() -> List[AllowedDeparture]:
    """THE table of allowed departures, one entry today. A departure is only
    for a limit of the Arrow representation; adding an entry is a decision of
    the benchmark's owners and a row of the README table.

    - HUGEINT as DECIMAL(38,0): Arrow has no 128-bit integer, so a komira
      column holding what DuckDB calls HUGEINT is a DECIMAL128(38,0). Not
      HUGEINT against INT64 (INT64 can overflow where HUGEINT does not), and
      not UHUGEINT: the same limit applies, but no query of the benchmark
      returns one, so it stays a failure until one does.
    """
    var out = List[AllowedDeparture]()
    out.append(
        AllowedDeparture(
            String("HUGEINT"),
            String("DECIMAL(38,0)"),
            String("Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"),
        )
    )
    return out^


def departure_reason(a: String, b: String) -> Optional[String]:
    """The reason of the allowed departure between the declared types `a` and
    `b` (in either order), or none when the pair is not in the table."""
    var table = allowed_departures()
    for i in range(len(table)):
        if (a == table[i].duckdb and b == table[i].komira) or (a == table[i].komira and b == table[i].duckdb):
            return Optional[String](table[i].reason.copy())
    return Optional[String]()
