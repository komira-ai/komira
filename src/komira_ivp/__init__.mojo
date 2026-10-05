# =============================================================================
# komira_ivp — the viewport protocol (IVP) v1 codec + validation.
# =============================================================================
#
# The wire contract of a viewport server: a viewport client posts
# a grid TICKET (source locator + filter/sort/computed Expr specs + row window +
# view_version) and gets back an Arrow-IPC (or JSON) slice + schema + rowcount +
# view_version. This package is the request half — the versioned Expr/plan wire
# serialization + the untrusted-ticket validation boundary — kept as a LIBRARY
# so it depends only on komira_core (+ komira_protobuf's varint), builds
# fast, and is unit-testable without linking the whole engine.
#
# Two properties are proven directly against this surface:
#   * round-trip: Expr -> encode -> bytes -> decode -> identical structural hash
#   * hostile-ticket: a malformed / out-of-allow-list ticket is rejected.
#
# Public surface (re-exported for `from komira_ivp import ...`):
# =============================================================================

from .ivp_bytes import (
    IvpWriter,
    IvpReader,
    IVP_MAX_BYTESTRING_LEN,
)

from .ivp_expr_codec import (
    encode_expr,
    decode_expr,
    encode_scalar,
    decode_scalar,
    IVP_MAX_EXPR_DEPTH,
)

from .ivp_ticket import (
    SourceLocator,
    IvpSortKey,
    IvpComputedCol,
    GridTicket,
    encode_grid_ticket,
    decode_grid_ticket,
    IVP_FACET_GRID,
    IVP_FACET_TEXT,
    IVP_SRC_PARQUET_FILE,
    IVP_SRC_GLOB,
    IVP_SRC_HIVE_DIR,
    IVP_SRC_ICEBERG_TABLE,
    IVP_VERSION_1,
)

from .ivp_validate import (
    IvpTicketLimits,
    validate_ticket,
    validate_ticket_bytes,
    decode_and_validate_grid_ticket,
)

from .ivp_response import (
    RowCount,
    GridResponse,
    encode_grid_response,
    decode_grid_response,
    IVP_COUNT_EXACT,
    IVP_COUNT_ESTIMATED,
    IVP_PAYLOAD_ARROW_IPC,
    IVP_PAYLOAD_JSON,
)
