# komira_plan_harness: canonical result text for conformance suites (render a
# RecordBatch or Table, parse an expected file, compare under the expected
# file's order and float policy, reporting every mismatch). canon_text.mojo
# holds the format, render.mojo the cells, float_text.mojo the float rules.
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
from .float_text import (
    FloatCell,
    FloatTolerance,
    float_cell_text,
    float_cells_match,
    parse_float_cell,
    ulp_distance,
)
from .parse import parse_canon
from .render import arrow_type_name, render_batch, render_column, render_table
