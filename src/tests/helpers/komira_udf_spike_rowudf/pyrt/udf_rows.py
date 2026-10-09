"""Row-shaped user functions (`df.map_rows(f)`): each takes one row and reads
its fields by name. The producer's read-set capture
(producer/komira_udf_readset.py) runs over them when the plan is built, and
the komira-test/python-row runtime runs them over the read set it was given.

The shared conformance cases of komira_udf_spike_abi name two of them by
bare name (`pick`, `pick_caught`); the tests load them as
`udf_rows:<name>`.
"""

# A row a function kept past its batch (keeps_row), read by read_kept.
KEPT = []
# The first row keeps_then_reads saw; the first row keeps_then_misreads saw.
KEPT_SAME = []
KEPT_MISS = []


def price_qty(row) -> float:
    """The bench function: reads 2 fields of however many the input has."""
    return row.price * row.qty


def price_qty_keys(row) -> float:
    """price_qty, reading its fields by subscript."""
    return row["price"] * row["qty"]


def branchy(row) -> float:
    """A data-dependent read: `c` only on rows where a <= 0."""
    return row.b if row.a > 0 else row.c


def pick(r) -> int:
    """The shared cases' ROW fixture: `a` where flag is set, else `b`."""
    return r.a if r.flag else r.b


def pick_caught(r) -> int:
    """pick, catching the error a read outside the read set raises."""
    if r.flag:
        return r.a
    try:
        return r.b
    except Exception:
        return -1


def pick_getattr_default(r) -> int:
    """pick through getattr with a default, which swallows AttributeError."""
    return r.a if r.flag else getattr(r, "b", -1)


def nullable_half(row) -> float | None:
    """None where `x` is null, else half of it: a null field reads None."""
    return None if row.x is None else row.x / 2


def via_helper(row) -> float:
    """Passes the row to other code: the scan cannot see what it reads."""
    return _total(row)


def _total(row):
    return row.price * row.qty


def by_name(row) -> float:
    """Reads a field whose name is computed: the scan cannot see it."""
    name = "pri" + "ce"
    return row[name]


def summed(row) -> float:
    """A generator over the row's fields: the generator captures the row."""
    return float(sum(row[c] for c in ("price", "qty")))


def keeps_row(row) -> float:
    """Keeps its row in a global past the batch."""
    KEPT.append(row)
    return row.price


def read_kept(row) -> float:
    """Reads the first row keeps_row kept, from a later batch."""
    return KEPT[0].price


def keeps_then_reads(row) -> float:
    """Keeps the first row it sees and returns that row's price on every
    call: in a later batch of the same instance the kept row is expired."""
    if not KEPT_SAME:
        KEPT_SAME.append(row)
    return KEPT_SAME[0].price


def keeps_then_misreads(row) -> float:
    """Keeps the first row it sees; on later calls reads `qty`, outside the
    read set {price}, through that kept row."""
    if not KEPT_MISS:
        KEPT_MISS.append(row)
        return row.price
    return KEPT_MISS[0].qty


def typo(row) -> float:
    """Reads a field the input does not have."""
    return row.prise * row.qty


def two_rows(row, other) -> float:
    """Not a row function: two parameters."""
    return row.price


def no_hint(row):
    """No return type hint."""
    return row.price
