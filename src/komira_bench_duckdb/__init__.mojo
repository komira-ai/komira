"""The DuckDB comparison arm of the komira benchmarks, and the value checks. See README.md.

| name | what it is |
|---|---|
| `check_duckdb_file`, `check_duckdb_bytes`, `PinCheck`, `DuckDbPin`, `duckdb_pins` | verify a user-supplied DuckDB binary against the pinned release by SHA-256 |
| `DuckDbSession`, `ProcessTransport`, `DuckDbTransport` | one persistent DuckDB process over stdin and stdout, queries bracketed by host-timed markers |
| `QueryTiming`, `FetchResult`, `FairnessSettings` | what a timed query, a fetched query and the setup return |
| `BenchClock` | the clock the markers are stamped with (system, or a manual counter for tests) |
| `Cell`, `ResultSet`, `parse_json_rows` | typed query results; DuckDB's JSON output as a result set |
| `signature_of`, `ResultSignature`, `ColumnSignature`, `compare_signatures`, `ValueVerdict` | the order-independent value signature and its tolerance rules |
| `check_order`, `OrderKey`, `OrderVerdict` | the row-order check of a query with ORDER BY |
| `ReferenceAnswer`, `ReferenceSet`, `format_reference`, `parse_references` | recorded answers as text a package can compile in |
"""

from .cells import (
    Cell,
    KIND_FLOAT,
    KIND_INT,
    KIND_NULL,
    KIND_TEXT,
    ResultSet,
)
from .clock import BenchClock
from .compare import (
    ABS_FLOOR,
    REL_TOL,
    ValueVerdict,
    compare_signatures,
    numbers_close,
)
from .order import OrderKey, OrderVerdict, check_order
from .pins import (
    DEFAULT_DUCKDB_VERSION,
    DuckDbPin,
    PIN_IS_ARCHIVE,
    PIN_MISMATCH,
    PIN_PINNED,
    PIN_UNKNOWN_VERSION,
    PinCheck,
    check_against_pins,
    check_duckdb_bytes,
    check_duckdb_file,
    duckdb_pins,
    find_pin,
)
from .reference import (
    ReferenceAnswer,
    ReferenceSet,
    format_reference,
    parse_references,
)
from .rows_json import parse_json_rows
from .session import (
    DuckDbSession,
    FairnessSettings,
    FetchResult,
    QueryTiming,
)
from .signature import (
    ColumnSignature,
    EXACT_LIMIT,
    ResultSignature,
    signature_of,
)
from .transport import DuckDbTransport, ProcessTransport, StdoutChunk
