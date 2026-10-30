"""The DuckDB comparison arm of the komira benchmarks, and the value checks. See README.md.

| name | what it is |
|---|---|
| `check_duckdb_file`, `check_duckdb_bytes`, `PinCheck`, `DuckDbPin`, `duckdb_pins` | verify a user-supplied DuckDB binary against the pinned release by SHA-256 |
| `open_pinned` | verify the binary against the pin and start it: the one entry point for the DuckDB arm |
| `DuckDbSession`, `ProcessTransport`, `DuckDbTransport` | one persistent DuckDB process over stdin and stdout, queries bracketed by host-timed markers, with a limit on silence and a way to stop the process |
| `parse_size`, `size_matches` | DuckDB's printed sizes (`953.6 MiB`) and the check of a read-back against the request |
| `QueryTiming`, `FetchResult`, `FairnessSettings` | what a timed query, a fetched query and the setup return; a timed query carries the page faults of the DuckDB process around it |
| `FaultCount`, `parse_stat_faults`, `read_stat_faults` | minor and major page faults of a process, read from its `/proc/<pid>/stat` (Linux; absent elsewhere) |
| `BenchClock` | the clock the markers are stamped with (system, or a manual counter for tests) |
| `Cell`, `ResultSet`, `parse_json_rows` | typed query results (an exact decimal is `KIND_DECIMAL`); DuckDB's JSON output as a result set, read by column types where DuckDB quotes numbers |
| `canonical_decimal`, `compare_decimals`, `ExactSum` | exact decimal text: one form per value, its order, and a sum with no rounding and no width limit |
| `signature_of`, `ResultSignature`, `ColumnSignature`, `compare_signatures`, `ValueVerdict` | the order-independent value signature and its tolerance rules |
| `AllowedDeparture`, `allowed_departures`, `departure_reason` | the table of allowed departures from "the same result as DuckDB" (HUGEINT as DECIMAL(38,0)) |
| `check_order`, `OrderKey`, `OrderVerdict` | the row-order check of a query with ORDER BY |
| `ReferenceAnswer`, `ReferenceSet`, `format_reference`, `parse_references` | recorded answers as text a package can compile in |
"""

from .cells import (
    Cell,
    KIND_DECIMAL,
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
from .declared_types import (
    AllowedDeparture,
    UNMAPPED_PREFIX,
    allowed_departures,
    departure_reason,
    decimal_type,
    duckdb_declared_type,
    is_declared_type,
    is_unmapped,
    unmapped_type,
)
from .decimal_text import ExactSum, canonical_decimal, compare_decimals
from .faults import FaultCount, parse_stat_faults, read_stat_faults
from .launch import open_pinned
from .memory import ParsedSize, parse_size, size_matches
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
    REFERENCE_FORMAT,
    ReferenceAnswer,
    ReferenceSet,
    format_reference,
    parse_references,
)
from .rows_json import EXACT_NONE, EXACT_WHOLE, exactness_of_type, parse_json_rows
from .session import (
    DuckDbSession,
    FairnessSettings,
    FetchResult,
    QueryTiming,
)
from .signature import (
    ColumnSignature,
    cell_hash,
    ResultSignature,
    signature_of,
)
from .transport import DuckDbTransport, ProcessTransport, StdoutChunk
