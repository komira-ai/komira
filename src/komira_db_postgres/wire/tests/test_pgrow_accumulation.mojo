"""komira_pg PgRow multi-row accumulation regression guard.

NO NETWORK. This pins the flat-storage fix for the multi-row (>=N) SIGSEGV in
`PgConnection.query`. BEFORE the fix, `PgRow` stored its per-column bytes as a
doubly-nested `List[List[UInt8]]`. When PgRows are accumulated in a
`List[PgRow]` and the backing List relocates them (growth realloc), Mojo
1.0.0b1's synthesized move/copy of a struct owning a `List[List[UInt8]]`
mis-tracks the inner heap-buffer liveness and corrupts the tcmalloc free-list
(SIGSEGV / SIGBUS in `List::_realloc` / `SLL_TryPop`) — empirically as early as
the second accumulated row against a live server.

The fix (pg_types.mojo): flatten `PgRow`'s storage from `List[List[UInt8]]` to
ONE contiguous `_data: List[UInt8]` plus an `_offsets: List[Int]` table. Every
`PgRow` field is now a SINGLE-level heap List (one heap buffer each), so the
container's per-element relocation is a clean per-field pointer move with no
second level of heap nesting for the compiler to mis-track. The container stays
`List[PgRow]` and the public API (`query -> PgRows`, `PgRow.get_*`) is
unchanged. (Restructuring PgRow into an OwnedPointer/nested-cell shape OR
swapping the container to `Slab[PgRow]` were both tried and each tripped a
SEPARATE Mojo 1.0.0b1 codegen heap-corruption — flattening the per-row storage
is the shape that is robust against both single-row and multi-row paths.)

This test builds the rows by hand (no live Postgres), exercising:
  * accumulation past every List[PgRow] growth boundary (N up to 500),
  * column-value integrity AFTER the growth moves (decode the stashed ints),
  * repeated build+teardown (50 trials) to surface any double-free / leak.
"""

from komira_pg.pg_types import PgRow, PgRows


def _make_row(row_idx: Int, ncols: Int) -> PgRow:
    """Build a PgRow whose column c holds the decimal ASCII text of
    (row_idx*1000 + c), so a later `get_int4` decode can verify the bytes
    survived the List[PgRow] growth moves intact. Built in the FLAT
    (data+offsets) shape that PgRow now stores natively. Stored as ASCII digits
    so the text decode round-trips cleanly (no non-UTF-8 bytes)."""
    var data = List[UInt8]()
    var offsets = List[Int]()
    offsets.append(0)
    var nulls = List[Bool]()
    var oids = List[UInt32]()
    for c in range(ncols):
        var val = row_idx * 1000 + c
        var s = String(val)
        var sb = s.as_bytes()
        for i in range(len(sb)):
            data.append(sb[i])
        offsets.append(len(data))
        nulls.append(False)
        oids.append(UInt32(23))  # OID_INT4
    return PgRow(data^, offsets^, nulls^, oids^)


def _build_rows(nrows: Int, ncols: Int) -> PgRows:
    """Mirror PgConnection.query's accumulation: List[PgRow] + repeated append
    across the growth boundaries."""
    var rows = List[PgRow]()
    for r in range(nrows):
        rows.append(_make_row(r, ncols))
    var col_names = List[String]()
    for c in range(ncols):
        col_names.append(String("c") + String(c))
    return PgRows(rows^, col_names^)


def _check(nrows: Int, ncols: Int) raises:
    var rs = _build_rows(nrows, ncols)
    if rs.__len__() != nrows:
        raise Error(
            "len mismatch: expected "
            + String(nrows)
            + " got "
            + String(rs.__len__())
        )
    # Decode every cell of every row AFTER all growth moves are done. If a
    # growth realloc had moved a nested heap List (the bug), these reads would
    # touch freed / reused bytes and either mis-decode or crash.
    for r in range(nrows):
        ref row = rs.row(r)
        if row.col_count() != ncols:
            raise Error("col_count mismatch at row " + String(r))
        for c in range(ncols):
            if row.is_null(c):
                raise Error("unexpected NULL at row " + String(r))
            var got = Int(row.get_int4(c))
            var want = r * 1000 + c
            if got != want:
                raise Error(
                    "cell VALUE CORRUPTION at row "
                    + String(r)
                    + " col "
                    + String(c)
                    + " (got "
                    + String(got)
                    + " want "
                    + String(want)
                    + ")"
                )


def test_pgrow_accumulation() raises:
    print("  test_pgrow_accumulation (flat PgRow multi-row fix)...")

    # The exact live threshold + beyond. N=3 was the original SIGSEGV.
    _check(1, 1)
    _check(2, 1)
    _check(3, 1)  # <-- the crash point pre-fix
    _check(3, 7)  # <-- a 7-column shape that surfaced a 2nd instance
    _check(5, 1)
    _check(10, 4)
    _check(100, 3)
    _check(127, 8)
    _check(128, 8)
    _check(129, 8)
    _check(200, 8)  # many growth reallocs
    _check(500, 4)
    print("    multi-row accumulation N up to 500 OK (no corruption)")

    # Build + tear down many times — surfaces any double-free / leak in the
    # List[PgRow] destructor.
    for _trial in range(50):
        _check(7, 7)
    print("    50 build+teardown trials OK (no double-free / leak)")


def main() raises:
    print("== komira_pg PgRow accumulation regression guard ==")
    test_pgrow_accumulation()
    print("== PASSED ==")
