# =============================================================================
# viewport_ticket.mojo — the viewport-protocol grid-facet TICKET model + wire codec.
# =============================================================================
#
# A grid ticket is the request a viewport client posts to a viewport server's
# `/v1/grid` route:
#
#   { source locator (parquet file | glob | Hive dir | Iceberg table),
#     filter (Expr), sort keys (Expr + dir), computed columns (alias + Expr),
#     projection (column names), row window [offset, limit), view_version }
#
# The ticket is a REMOTE-CLIENT-POSTED, UNTRUSTED byte blob. The codec here is
# pure structure + strict framing (magic + version + facet + positional
# fields); the SEMANTIC untrusted-ticket policy (size / depth / count caps,
# allow-list enforcement, UDF rejection) lives in `viewport_validate.mojo`, which
# runs AFTER a structural decode. Decode itself is already fail-closed: it
# raises on a bad magic, an unknown version/facet/source-kind, a count past its
# structural cap, or any malformed byte (via the strict ViewportReader + the Expr
# allow-list decoder).
#
# Collections that hold `Expr` use `Slab[T]` (not `List[T]`), because `Expr` is
# Movable-only (it owns OwnedPointer children) and `List[T]` requires
# `Copyable & Movable` — the SAME reason `ExprArray = Slab[Expr]` in
# logical_plan.mojo. `projection` stays `List[String]` (String is Copyable).
#
# Encapsulation: value-typed structs + owned Slabs/Lists. No UnsafePointer
# crosses the boundary. Mojo 1.0.0b2 (def-only).
# =============================================================================

from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr

from .viewport_bytes import ViewportWriter, ViewportReader
from .viewport_expr_codec import encode_expr, decode_expr


# --- Wire framing constants --------------------------------------------------
# Magic "IVP1" — the first four bytes of every viewport-protocol message. A
# blob not starting with these bytes is rejected before any field is read.
# The bytes are the wire format and stay as they are; only the Mojo names of
# the constants carry the package's name.
comptime VIEWPORT_MAGIC_0: UInt8 = 0x49  # 'I'
comptime VIEWPORT_MAGIC_1: UInt8 = 0x56  # 'V'
comptime VIEWPORT_MAGIC_2: UInt8 = 0x50  # 'P'
comptime VIEWPORT_MAGIC_3: UInt8 = 0x31  # '1'

comptime VIEWPORT_VERSION_1: UInt64 = 1

# Facets (one protocol, two facets — grid now, text added by the M7 gate).
comptime VIEWPORT_FACET_GRID: UInt8 = 0
comptime VIEWPORT_FACET_TEXT: UInt8 = 1  # reserved (M7 textstore gate)

# Source-locator kinds — the engine-scannable analytic table surface.
comptime VIEWPORT_SRC_PARQUET_FILE: UInt8 = 0
comptime VIEWPORT_SRC_GLOB: UInt8 = 1
comptime VIEWPORT_SRC_HIVE_DIR: UInt8 = 2
comptime VIEWPORT_SRC_ICEBERG_TABLE: UInt8 = 3

# STRUCTURAL decode caps (a second, SEMANTIC layer lives in viewport_validate.mojo).
# These bound the container allocations a hostile count field can force.
comptime VIEWPORT_MAX_PROJECTION_COLS: Int = 4096
comptime VIEWPORT_MAX_SORT_KEYS: Int = 256
comptime VIEWPORT_MAX_COMPUTED_COLS: Int = 1024


def _src_kind_is_valid(kind: UInt8) -> Bool:
    return (
        kind == VIEWPORT_SRC_PARQUET_FILE or kind == VIEWPORT_SRC_GLOB
        or kind == VIEWPORT_SRC_HIVE_DIR or kind == VIEWPORT_SRC_ICEBERG_TABLE
    )


struct SourceLocator(Movable, Copyable):
    """WHERE the grid reads from: a kind discriminant + a locator string
    (a parquet path, a glob pattern, a Hive directory, or an Iceberg table
    URI)."""

    var kind: UInt8
    var locator: String

    def __init__(out self, kind: UInt8, locator: String):
        self.kind = kind
        self.locator = locator

    def copy(self) -> Self:
        return Self(self.kind, self.locator.copy())


struct ViewportSortKey(Movable, Deinitable):
    """One sort key: an Expr (usually a column reference) + a direction."""

    var key: Expr
    var descending: Bool

    def __init__(out self, var key: Expr, descending: Bool):
        self.key = key^
        self.descending = descending


struct ViewportComputedCol(Movable, Deinitable):
    """One computed / derived column: an output name + an Expr over the row.

    NOTE: the output-name field is `name`, not `alias` — `alias` is a reserved
    Mojo keyword and cannot be a struct field / local name."""

    var name: String
    var expr: Expr

    def __init__(out self, name: String, var expr: Expr):
        self.name = name
        self.expr = expr^


struct GridTicket(Movable, Deinitable):
    """The decoded grid-facet request. All fields owned by value."""

    var source: SourceLocator
    var projection: List[String]  # empty => all columns
    var filter: Optional[Expr]
    var sort_keys: Slab[ViewportSortKey]
    var computed: Slab[ViewportComputedCol]
    var offset: UInt64
    var limit: UInt64
    var view_version: UInt64

    def __init__(
        out self,
        var source: SourceLocator,
        var projection: List[String],
        var filter: Optional[Expr],
        var sort_keys: Slab[ViewportSortKey],
        var computed: Slab[ViewportComputedCol],
        offset: UInt64,
        limit: UInt64,
        view_version: UInt64,
    ):
        self.source = source^
        self.projection = projection^
        self.filter = filter^
        self.sort_keys = sort_keys^
        self.computed = computed^
        self.offset = offset
        self.limit = limit
        self.view_version = view_version

    @staticmethod
    def minimal(var source: SourceLocator, offset: UInt64, limit: UInt64) -> GridTicket:
        """A window-only ticket (no filter / sort / computed / projection) —
        the unfiltered fast path over the whole table."""
        var no_filter: Optional[Expr] = None
        return GridTicket(
            source^,
            List[String](),
            no_filter^,
            Slab[ViewportSortKey](),
            Slab[ViewportComputedCol](),
            offset,
            limit,
            UInt64(0),
        )


# =============================================================================
# Encode.
# =============================================================================


def encode_grid_ticket(t: GridTicket) raises -> List[UInt8]:
    """Serialize a GridTicket to the viewport-protocol wire bytes (magic + version + grid
    facet + positional fields)."""
    var w = ViewportWriter(capacity_hint=256)
    w.write_u8(VIEWPORT_MAGIC_0)
    w.write_u8(VIEWPORT_MAGIC_1)
    w.write_u8(VIEWPORT_MAGIC_2)
    w.write_u8(VIEWPORT_MAGIC_3)
    w.write_uvarint(VIEWPORT_VERSION_1)
    w.write_u8(VIEWPORT_FACET_GRID)

    # Source locator.
    w.write_u8(t.source.kind)
    w.write_string(t.source.locator)

    # Projection.
    w.write_uvarint(UInt64(len(t.projection)))
    for i in range(len(t.projection)):
        w.write_string(t.projection[i])

    # Filter (optional).
    if t.filter:
        w.write_bool(True)
        encode_expr(w, t.filter.value())
    else:
        w.write_bool(False)

    # Sort keys.
    w.write_uvarint(UInt64(t.sort_keys.len()))
    for i in range(t.sort_keys.len()):
        encode_expr(w, t.sort_keys[i].key)
        w.write_bool(t.sort_keys[i].descending)

    # Computed columns.
    w.write_uvarint(UInt64(t.computed.len()))
    for i in range(t.computed.len()):
        w.write_string(t.computed[i].name)
        encode_expr(w, t.computed[i].expr)

    # Window + version.
    w.write_uvarint(t.offset)
    w.write_uvarint(t.limit)
    w.write_uvarint(t.view_version)

    return w.take_bytes()


# =============================================================================
# Decode (fail-closed structural parse of untrusted bytes).
# =============================================================================


def decode_grid_ticket(data: Span[UInt8, _]) raises -> GridTicket:
    """Parse viewport-protocol grid-ticket bytes. RAISES on bad magic, unknown version /
    facet / source-kind, a structural count past its cap, a disallowed Expr
    node, or any malformed / truncated / trailing byte."""
    var r = ViewportReader.from_span(data)

    var m0 = r.read_u8()
    var m1 = r.read_u8()
    var m2 = r.read_u8()
    var m3 = r.read_u8()
    if (
        m0 != VIEWPORT_MAGIC_0 or m1 != VIEWPORT_MAGIC_1
        or m2 != VIEWPORT_MAGIC_2 or m3 != VIEWPORT_MAGIC_3
    ):
        raise Error("viewport: bad magic — not a viewport-protocol message")

    var version = r.read_uvarint()
    if version != VIEWPORT_VERSION_1:
        raise Error("viewport: unsupported protocol version " + String(version))

    var facet = r.read_u8()
    if facet != VIEWPORT_FACET_GRID:
        raise Error(
            "viewport: facet " + String(Int(facet)) + " is not the grid facet "
            "(text facet arrives with the M7 textstore gate)"
        )

    # Source locator.
    var src_kind = r.read_u8()
    if not _src_kind_is_valid(src_kind):
        raise Error("viewport: unknown source-locator kind " + String(Int(src_kind)))
    var locator = r.read_string()
    var source = SourceLocator(src_kind, locator)

    # Projection.
    var n_proj64 = r.read_uvarint()
    if n_proj64 > UInt64(VIEWPORT_MAX_PROJECTION_COLS):
        raise Error(
            "viewport: projection column count " + String(n_proj64)
            + " exceeds cap " + String(VIEWPORT_MAX_PROJECTION_COLS)
        )
    var projection = List[String]()
    for _ in range(Int(n_proj64)):
        projection.append(r.read_string())

    # Filter (optional).
    var filter: Optional[Expr] = None
    var has_filter = r.read_bool()
    if has_filter:
        filter = decode_expr(r)

    # Sort keys.
    var n_sort64 = r.read_uvarint()
    if n_sort64 > UInt64(VIEWPORT_MAX_SORT_KEYS):
        raise Error(
            "viewport: sort-key count " + String(n_sort64)
            + " exceeds cap " + String(VIEWPORT_MAX_SORT_KEYS)
        )
    var sort_keys = Slab[ViewportSortKey]()
    for _ in range(Int(n_sort64)):
        var key = decode_expr(r)
        var desc = r.read_bool()
        sort_keys.append(ViewportSortKey(key^, desc))

    # Computed columns.
    var n_comp64 = r.read_uvarint()
    if n_comp64 > UInt64(VIEWPORT_MAX_COMPUTED_COLS):
        raise Error(
            "viewport: computed-column count " + String(n_comp64)
            + " exceeds cap " + String(VIEWPORT_MAX_COMPUTED_COLS)
        )
    var computed = Slab[ViewportComputedCol]()
    for _ in range(Int(n_comp64)):
        var out_name = r.read_string()
        var cexpr = decode_expr(r)
        computed.append(ViewportComputedCol(out_name, cexpr^))

    # Window + version.
    var offset = r.read_uvarint()
    var limit = r.read_uvarint()
    var view_version = r.read_uvarint()

    # Reject any trailing bytes — a well-formed ticket ends exactly here.
    r.expect_end()

    return GridTicket(
        source^,
        projection^,
        filter^,
        sort_keys^,
        computed^,
        offset,
        limit,
        view_version,
    )
