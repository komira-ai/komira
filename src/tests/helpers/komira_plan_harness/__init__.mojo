# komira_plan_harness: canonical result text for conformance suites (render a
# RecordBatch or Table, parse an expected file, compare under the expected
# file's order and float policy, reporting every mismatch). canon_text.mojo
# holds the format, render.mojo the cells, float_text.mojo the float rules.
# door.mojo runs a plan through a plan-door shared library (Door A, an Arrow
# C stream; Door B, Arrow IPC bytes) behind a value-only API.
from .canon_text import (
    CANON_MAGIC,
    ORDER_KEYS,
    ORDER_NONE,
    ORDER_TOTAL,
    CanonPolicy,
    CanonText,
)
from .check import (
    check_batch,
    check_table,
    require_batch_matches,
    require_table_matches,
)
from .compare import CompareReport, Mismatch, compare_canon
from .door import (
    DOOR_ERR_BUFFER_TOO_SMALL,
    DOOR_ERR_ENGINE,
    DOOR_ERR_NULL_ARG,
    DOOR_ERR_NULL_CTX,
    DOOR_OK,
    PLAN_DOOR_ABI_VERSION,
    PLAN_DOOR_FLAG,
    EndpointRefusal,
    PlanDoor,
    door_path_from_args,
    parse_endpoint_refusal,
)
from .door_ipc import decode_ipc_stream
from .float_text import (
    FloatCell,
    FloatTolerance,
    float_cell_text,
    float_cells_match,
    parse_float_cell,
    ulp_distance,
)
from .parse import parse_canon
from .render import render_batch, render_column, render_table
from .type_text import arrow_type_name
