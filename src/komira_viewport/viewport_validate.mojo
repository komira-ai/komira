# =============================================================================
# viewport_validate.mojo — the UNTRUSTED-TICKET validation boundary.
# =============================================================================
#
# UNTRUSTED-TICKET validation at the server boundary: schema-validate,
# depth/size-cap, reject UDF references unless allow-listed. A viewport server
# treats EVERY ticket as hostile (a remote client can post
# arbitrary bytes). Defense is layered:
#
#   Layer 0 (SIZE):   `validate_ticket_bytes` rejects an over-large blob BEFORE
#                     a single field is parsed — no unbounded work on junk.
#   Layer 1 (STRUCT): `decode_grid_ticket` fails closed on bad magic / version /
#                     facet / unknown source kind / count-cap / trailing bytes.
#   Layer 2 (EXPR):   the Expr decoder enforces the SIX-tag allow-list + a per-
#                     tree depth cap; agg-fn / window-fn / UDF / correlated-
#                     subquery / regexp nodes are rejected there (UDF references
#                     live under non-allow-listed tags, so "reject UDF unless
#                     allow-listed" holds by construction).
#   Layer 3 (SEMANTIC): `validate_ticket` bounds the TOTAL Expr node budget
#                     across all sub-trees (a ticket can't smuggle thousands of
#                     shallow-but-wide trees), caps the window `limit`, and
#                     rejects empty locators / blank projection or alias names.
#
# `decode_and_validate_grid_ticket` runs all four layers in order — the single
# entry point a server calls on the raw request body. Errors are plain `raises`;
# a server maps them to a 400 (the client sent a bad ticket) — never a 500.
#
# Encapsulation: pure value logic. No UnsafePointer crosses the boundary.
# Mojo 1.0.0b2 (def-only).
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_ALIAS,
)

from .viewport_ticket import GridTicket, decode_grid_ticket


struct ViewportTicketLimits(Movable, Copyable):
    """The hostile-ticket budget a server enforces at its request boundary. All
    caps are policy — a deployment (desktop loopback vs remote) may tighten them,
    but the defaults are safe for both."""

    var max_ticket_bytes: Int
    var max_total_expr_nodes: Int
    var max_window_limit: UInt64

    def __init__(
        out self,
        max_ticket_bytes: Int = 256 * 1024,
        max_total_expr_nodes: Int = 4096,
        max_window_limit: UInt64 = UInt64(1_000_000),
    ):
        self.max_ticket_bytes = max_ticket_bytes
        self.max_total_expr_nodes = max_total_expr_nodes
        self.max_window_limit = max_window_limit

    def copy(self) -> Self:
        return Self(
            self.max_ticket_bytes,
            self.max_total_expr_nodes,
            self.max_window_limit,
        )

    @staticmethod
    def default() -> Self:
        return Self()


def _count_expr_nodes(e: Expr) -> Int:
    """Count nodes in an ALREADY-allow-list-validated Expr tree. Only the six
    v1 tags carry children, so this walk is total over what a decoded ticket can
    contain (an unknown tag never survives decode to reach here)."""
    var tag = e.tag
    if tag == EXPR_BINARY_OP:
        return 1 + _count_expr_nodes(e.binary_left_ref()) + _count_expr_nodes(
            e.binary_right_ref()
        )
    if tag == EXPR_UNARY_OP:
        return 1 + _count_expr_nodes(e.unary_child_ref())
    if tag == EXPR_STRING_OP:
        return 1 + _count_expr_nodes(e.string_op_child_ref())
    if tag == EXPR_ALIAS:
        return 1 + _count_expr_nodes(e.alias_child_ref())
    # COL_REF / LITERAL are leaves.
    return 1


def validate_ticket_bytes(data: Span[UInt8, _], limits: ViewportTicketLimits) raises:
    """Layer 0: reject an over-large ticket blob before parsing anything."""
    if len(data) > limits.max_ticket_bytes:
        raise Error(
            "viewport: ticket size " + String(len(data)) + " bytes exceeds cap "
            + String(limits.max_ticket_bytes) + " bytes"
        )
    if len(data) < 6:
        # magic(4) + version(>=1) + facet(1) is the structural floor.
        raise Error("viewport: ticket too short to be a valid viewport-protocol message")


def validate_ticket(t: GridTicket, limits: ViewportTicketLimits) raises:
    """Layer 3: semantic validation of an already-decoded ticket."""
    # Non-empty source locator.
    if t.source.locator.byte_length() == 0:
        raise Error("viewport: empty source locator")

    # Window sanity: limit must be within the budget (offset is unbounded — a
    # deep offset is a scroll target, honored via the range primitive).
    if t.limit > limits.max_window_limit:
        raise Error(
            "viewport: window limit " + String(t.limit) + " exceeds cap "
            + String(limits.max_window_limit)
        )

    # Total Expr node budget across filter + sort keys + computed columns.
    var total_nodes = 0
    if t.filter:
        total_nodes = total_nodes + _count_expr_nodes(t.filter.value())
    for i in range(t.sort_keys.len()):
        total_nodes = total_nodes + _count_expr_nodes(t.sort_keys[i].key)
    for i in range(t.computed.len()):
        total_nodes = total_nodes + _count_expr_nodes(t.computed[i].expr)
    if total_nodes > limits.max_total_expr_nodes:
        raise Error(
            "viewport: total Expr node count " + String(total_nodes)
            + " exceeds cap " + String(limits.max_total_expr_nodes)
        )

    # Projection names must be non-blank.
    for i in range(len(t.projection)):
        if t.projection[i].byte_length() == 0:
            raise Error("viewport: blank projection column name at index " + String(i))

    # Computed-column names must be non-blank (they name output columns).
    for i in range(t.computed.len()):
        if t.computed[i].name.byte_length() == 0:
            raise Error("viewport: blank computed-column name at index " + String(i))

    # ★ THE TICKET MAY NOT DECLARE ONE OUTPUT NAME TWICE.
    #
    # The names a ticket DECLARES for its window are exactly `projection ++
    # [c.name for c in computed]` — that is the list a server turns into the
    # top `Project`, in that order — so the
    # duplicate predicate is a property of that one list rather than of a
    # catalogue of collision shapes. When `projection` is empty the list is just
    # the computed names, and the passthrough columns come from the SOURCE
    # schema, which this layer cannot see: a computed name that collides with a
    # source column is caught at serve time by `_assert_unique_output_names`,
    # which reads the resolved output schema. THAT is the load-bearing check;
    # this one is the door — it refuses the half of the class a hostile client
    # can express without any I/O at all, before a single footer is read, and
    # names which two positions collided.
    var declared = List[String]()
    for i in range(len(t.projection)):
        declared.append(t.projection[i].copy())
    for i in range(t.computed.len()):
        declared.append(t.computed[i].name.copy())
    for i in range(len(declared)):
        for j in range(i + 1, len(declared)):
            if declared[i] == declared[j]:
                raise Error(
                    "viewport: the ticket declares the output name '"
                    + declared[i]
                    + "' twice (declared names are the projection followed by"
                    + " the computed columns; positions "
                    + String(i)
                    + " and "
                    + String(j)
                    + "). A window cannot carry two columns with one name."
                )


def decode_and_validate_grid_ticket(
    data: Span[UInt8, _], limits: ViewportTicketLimits
) raises -> GridTicket:
    """The single hostile-ticket entry point: run all four defense layers in
    order (size → structural decode → Expr allow-list/depth → semantic) and
    return the validated ticket, or RAISE on the first violation."""
    validate_ticket_bytes(data, limits)          # Layer 0
    var t = decode_grid_ticket(data)             # Layers 1 + 2
    validate_ticket(t, limits)                   # Layer 3
    return t^
