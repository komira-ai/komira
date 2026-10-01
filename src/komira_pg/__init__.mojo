"""`komira_pg` — native Postgres pgwire-v3 client (SCRAM-SHA-256 over TLS).

Opens a TCP connection, negotiates TLS 1.3 (with the SSLRequest preamble),
completes SCRAM-SHA-256 authentication, runs simple and extended-protocol
queries and reads the result rows.

Public surface:
  * PgConfig       — connection parameters.
  * PgConnection   — one server session (connect / execute / query / close).
  * PgRow / PgRows — result rows over the closed OID set.
  * PgValue        — typed parameter value for extended-protocol binds.
  * PgError        — server ErrorResponse / transport error.
  * PgQueryOp / PgTxAsyncOp — poll-shaped query and transaction operations
    for a reactor-driven caller.

Substrate: komira_async (TCP, reactor, DNS), komira_http's TLS layer (s2n),
komira_crypto (SHA-256 / HMAC / PBKDF2 / base64 / CSPRNG).

Not in this package: connection pooling (a pool belongs to the caller).
"""

from .pg_types import (
    PgError,
    PgValue,
    PgRow,
    PgRows,
    OID_INT8,
    OID_INT4,
    OID_TEXT,
    OID_VARCHAR,
    OID_JSONB,
    OID_UUID,
    OID_TIMESTAMPTZ,
    OID_TEXT_ARRAY,
)
from .connection import PgConfig, PgConnection, PreparedStatement
from .pg_tls import (
    PgReactorStream,
    pg_reactor_connect,
    PG_RECV_DONE,
    PG_RECV_PENDING,
    PG_RECV_EOF,
)
from .pg_query_op import (
    PgQueryOp,
    PgReadFrame,
    PG_OP_PENDING,
    PG_OP_READY,
    PG_OP_ERR,
)
from .pg_tx_op import (
    PgTxAsyncOp,
    TxStep,
    PG_TX_CAS_MISS_MARKER,
)
