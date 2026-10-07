# =============================================================================
# komira_viewport — the viewport protocol v1 codec + validation.
# =============================================================================
#
# The wire contract of a viewport server: a viewport client posts
# a grid TICKET (source locator + filter/sort/computed Expr specs + row window +
# view_version) and gets back an Arrow-IPC (or JSON) slice + schema + rowcount +
# view_version. This package is the request half — the versioned Expr/plan wire
# serialization + the untrusted-ticket validation boundary — kept as a LIBRARY
# so it depends only on komira_plan_expr and komira_collections (+ komira_protobuf's varint), builds
# fast, and is unit-testable without linking the whole engine.
#
# Two properties are proven directly against this surface:
#   * round-trip: Expr -> encode -> bytes -> decode -> identical structural hash
#   * hostile-ticket: a malformed / out-of-allow-list ticket is rejected.
#
# Public surface (re-exported for `from komira_viewport import ...`):
# =============================================================================

from .viewport_bytes import (
    ViewportWriter,
    ViewportReader,
    VIEWPORT_MAX_BYTESTRING_LEN,
)

from .viewport_expr_codec import (
    encode_expr,
    decode_expr,
    encode_scalar,
    decode_scalar,
    VIEWPORT_MAX_EXPR_DEPTH,
)

from .viewport_ticket import (
    SourceLocator,
    ViewportSortKey,
    ViewportComputedCol,
    GridTicket,
    encode_grid_ticket,
    decode_grid_ticket,
    VIEWPORT_FACET_GRID,
    VIEWPORT_FACET_TEXT,
    VIEWPORT_SRC_PARQUET_FILE,
    VIEWPORT_SRC_GLOB,
    VIEWPORT_SRC_HIVE_DIR,
    VIEWPORT_SRC_ICEBERG_TABLE,
    VIEWPORT_VERSION_1,
)

from .viewport_validate import (
    ViewportTicketLimits,
    validate_ticket,
    validate_ticket_bytes,
    decode_and_validate_grid_ticket,
)

from .viewport_response import (
    RowCount,
    GridResponse,
    encode_grid_response,
    decode_grid_response,
    VIEWPORT_COUNT_EXACT,
    VIEWPORT_COUNT_ESTIMATED,
    VIEWPORT_PAYLOAD_ARROW_IPC,
    VIEWPORT_PAYLOAD_JSON,
)
