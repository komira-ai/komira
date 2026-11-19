# =============================================================================
# asof_equi_key -- `EquiKeyCmp`, the result of comparing two rows' equi-key
# tuples: their sort ORDER and, separately, whether they MATCH
# =============================================================================
#
# The ASOF walker sorts both sides on `(equi_keys..., asof)` and merges them
# with a cursor. The cursor needs a total order, so NULL is given a place in
# it: NULL is its own class, before every non-NULL. Under that order two NULLs
# are adjacent and compare 0.
#
# That 0 is an ordering, not a join match. `NULL = NULL` is UNKNOWN in SQL and
# never joins (DuckDB: an ASOF JOIN row whose equi key is NULL matches
# nothing). A walker that read `compare(...) == 0` as "these rows join" would
# join a NULL-keyed left row to a NULL-keyed right group. The ordering must
# stay as it is (the cursor needs it); what a caller needs is a way to ask the
# second question.
#
# So the answer is a type. `EquiKeyCmp` carries both answers and is not an
# `Int`, so `if c == 0:` does not compile: a caller writes `c.order` (to move
# a cursor) or `c.matched` (the join predicate), and chooses in writing it.
# =============================================================================


struct EquiKeyCmp(Copyable, Movable):
    """The result of comparing two rows' equi-key tuples: their ORDER, and,
    separately, whether they MATCH.

    | left key | right key | `order` | `matched` | why                        |
    |----------|-----------|---------|-----------|----------------------------|
    | 7        | 7         | 0       | True      | equal values               |
    | 7        | 9         | -1      | False     | ordered, unequal           |
    | NULL     | 9         | -1      | False     | NULL sorts first           |
    | 9        | NULL      | +1      | False     | NULL sorts first           |
    | NULL     | NULL      | 0       | False     | adjacent in sort order,    |
    |          |           |         |           | UNKNOWN in SQL             |

    `matched` implies `order == 0`; the converse is false (the last row).

    Fields:
        order: -1 / 0 / +1, a total order over the key tuple with NULL as its
            own class before every non-NULL. Moves a merge cursor.
        matched: True iff the two key tuples are equal and no key column is
            NULL on either side. The join predicate.
    """

    var order: Int
    var matched: Bool

    @always_inline
    def __init__(out self, order: Int, matched: Bool):
        self.order = order
        self.matched = matched

    @staticmethod
    @always_inline
    def equal_and_matched() -> Self:
        """Two non-NULL key tuples that compare equal: a join match."""
        return Self(0, True)

    @staticmethod
    @always_inline
    def ordered(order: Int) -> Self:
        """An ordering that is never a match: unequal tuples do not join, and
        a pair with a NULL on one side is UNKNOWN, which does not join
        either. `order` is kept as given."""
        return Self(order, False)

    @staticmethod
    @always_inline
    def unknown() -> Self:
        """Key tuples adjacent in sort order that do not join (a NULL on both
        sides): `order == 0` for the cursor, `matched == False` for SQL."""
        return Self(0, False)
