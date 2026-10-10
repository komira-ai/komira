# komira_viewport

The request and response codec of the viewport protocol, version 1: a client
asks for a window of rows from a table with a grid ticket, and the server
answers with a grid response. A `GridTicket` carries a source locator (a
Parquet file, a glob, a Hive directory or an Iceberg table), an optional column
projection, an optional filter, sort keys and computed columns (each a
`komira_plan_expr` `Expr`), a row window (`offset`, `limit`) and a view
version. `encode_grid_ticket` and `decode_grid_ticket` write and read its wire
bytes (magic `IVP1`, a varint version, a facet byte, then the fields in order);
`encode_expr` and `decode_expr` do the same for one `Expr`. A `GridResponse`
carries the view version, a `RowCount` that says whether the count is exact or
an estimate with an error bound, a payload kind (Arrow IPC or JSON) and the
payload bytes.

A ticket comes from an untrusted client, so decoding is a checked boundary.
`decode_and_validate_grid_ticket` refuses, by raising: a blob over the size cap
or too short to hold a header; a wrong magic, version or facet; an unknown
source kind; truncated input or trailing bytes; strings that are not UTF-8;
counts over their caps; an `Expr` node outside the allow-list (aggregate
functions and user-defined functions are not accepted) or nested deeper than
`VIEWPORT_MAX_EXPR_DEPTH`; and, after decoding, an empty locator, a window
larger than the limit, too many `Expr` nodes in total, a blank column name and
an output name declared twice. The caps are a `ViewportTicketLimits`.

This package does not read any data, check column names against a table's
schema, run a query, or build or parse the response payload: the payload is
opaque bytes to it.

## Examples

A ticket for a filtered, sorted window with a computed column, encoded and
decoded through the checked entry point:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, BIN_GT, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_viewport import GridTicket, SourceLocator, ViewportComputedCol, ViewportSortKey, ViewportTicketLimits, VIEWPORT_SRC_GLOB, decode_and_validate_grid_ticket, encode_grid_ticket

var projection: List[String] = [String("l_orderkey"), String("l_quantity")]
var sort_keys = Slab[ViewportSortKey]()
sort_keys.append(ViewportSortKey(Expr.col_ref("l_quantity"), True))
var computed = Slab[ViewportComputedCol]()
computed.append(
    ViewportComputedCol(
        "gross",
        Expr.binary(BIN_MUL, Expr.col_ref("l_extendedprice"), Expr.col_ref("l_quantity")),
    )
)
var ticket = GridTicket(
    SourceLocator(VIEWPORT_SRC_GLOB, "lineitem/*.parquet"),
    projection^,
    Optional[Expr](
        Expr.binary(BIN_GT, Expr.col_ref("l_quantity"), Expr.literal(ScalarValue.from_int64(30)))
    ),
    sort_keys^,
    computed^,
    UInt64(1000),  # offset
    UInt64(50),  # limit
    UInt64(7),  # view version
)

var wire = encode_grid_ticket(ticket)
var back = decode_and_validate_grid_ticket(Span(wire), ViewportTicketLimits.default())
assert_equal(back.source.locator, "lineitem/*.parquet")
assert_equal(len(back.projection), 2)
assert_equal(back.offset, UInt64(1000))
assert_equal(back.limit, UInt64(50))
assert_equal(back.view_version, UInt64(7))
assert_true(Bool(back.filter))
assert_true(back.sort_keys[0].descending)
assert_equal(back.computed[0].name, "gross")

# Encoding the decoded ticket gives the same bytes.
var again = encode_grid_ticket(back)
assert_equal(len(again), len(wire))
for i in range(len(wire)):
    assert_equal(again[i], wire[i])
```

Hostile tickets are refused before anything uses them:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_viewport import GridTicket, SourceLocator, ViewportTicketLimits, VIEWPORT_SRC_PARQUET_FILE, decode_and_validate_grid_ticket, encode_grid_ticket

def refusal(data: List[UInt8], limits: ViewportTicketLimits) -> String:
    try:
        _ = decode_and_validate_grid_ticket(Span(data), limits)
    except e:
        return String(e)
    return String("accepted")

var small = encode_grid_ticket(
    GridTicket.minimal(SourceLocator(VIEWPORT_SRC_PARQUET_FILE, "t.parquet"), UInt64(0), UInt64(100))
)
var limits = ViewportTicketLimits.default()
assert_true(refusal(small, limits) == "accepted")

var bad_magic = small.copy()
bad_magic[0] = 0xFF
assert_true("bad magic" in refusal(bad_magic, limits))

var trailing = small.copy()
trailing.append(0)
assert_true("trailing bytes" in refusal(trailing, limits))

var too_wide = encode_grid_ticket(
    GridTicket.minimal(SourceLocator(VIEWPORT_SRC_PARQUET_FILE, "t.parquet"), UInt64(0), UInt64(5_000_000))
)
assert_true("window limit" in refusal(too_wide, limits))
assert_true("exceeds cap" in refusal(small, ViewportTicketLimits(max_ticket_bytes=8)))
```

A response with an estimated row count and an opaque payload:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_viewport import RowCount, VIEWPORT_COUNT_ESTIMATED, VIEWPORT_PAYLOAD_JSON, decode_grid_response, encode_grid_response

var payload: List[UInt8] = [0x5B, 0x5D]  # the bytes of "[]"
var wire = encode_grid_response(
    UInt64(7),
    RowCount.estimated(UInt64(1_234_000), UInt64(50_000), "refine-1"),
    VIEWPORT_PAYLOAD_JSON,
    Span(payload),
)
var resp = decode_grid_response(Span(wire))
assert_equal(resp.view_version, UInt64(7))
assert_equal(resp.rowcount.kind, VIEWPORT_COUNT_ESTIMATED)
assert_equal(resp.rowcount.value, UInt64(1_234_000))
assert_equal(resp.rowcount.error_bound, UInt64(50_000))
assert_equal(resp.rowcount.refine_token, "refine-1")
assert_equal(resp.payload_kind, VIEWPORT_PAYLOAD_JSON)
assert_equal(len(resp.payload), 2)
```
