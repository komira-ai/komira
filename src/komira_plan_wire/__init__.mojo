from .plan_wire_codec import (
    PLAN_WIRE_FORMAT_VERSION,
    # ★ THE VERSION IS A SET, NOT A NUMBER. A write-carrying envelope
    # declares `PLAN_WIRE_WRITE_TARGET_MIN_VERSION` (5) and a plain one
    # `PLAN_WIRE_FORMAT_VERSION` (4), so a reader that compares against
    # `PLAN_WIRE_FORMAT_VERSION` alone refuses every write envelope.
    # `PLAN_WIRE_FORMAT_VERSION` remains exported because it is what a PLAIN
    # envelope declares and several tests author bytes by hand.
    plan_wire_supported_versions,
    plan_to_bytes,
    plan_to_bytes_with_write_target,
    plan_from_bytes,
    plan_envelope_from_bytes,
    DecodedPlanEnvelope,
    plan_round_trip,
    # ★ THE PRODUCER-SIDE HALF. Everything else in this package serves a
    # CONSUMER: bytes arrive and become a plan. `schema_to_bytes` serves an
    # AUTHOR — a non-Mojo frontend that must emit `WireParquetSource.schema`
    # for a file it wants scanned, and cannot derive `dtype_code` without a
    # second copy of this package's private table. See its docstring.
    schema_to_bytes,
    # ★ THE FOOTERLESS TWIN OF THE ABOVE, for a frontend authoring a CSV or
    # JSONL scan. A parquet author needs only the schema; a footerless author
    # also needs `fingerprint` / `structural_id` / `kind_id` /
    # `snapshot_policy` / `orientation`, none of which it may compute — see the
    # docstring for why each one is a wrong-plan-cache risk and not a decode
    # risk. So it gets the WHOLE `WireScanBinding` and splices it.
    binding_to_bytes,
    # ★ ITS READ-SIDE PARTNER FOR AN OPEN SCAN KIND: a non-Mojo author names
    # a kind's params as a typed map (a `WireScanBinding` with only `params`
    # set) and the kind builds the rest. See its docstring.
    scan_params_from_bytes,
    # ★ THE PER-FIELD LEDGER'S TOKENS. Exported for the same reason the two gates
    # below export theirs: a test asserting on one of these imports it, so the
    # assertion tracks the constant rather than a STRING LITERAL that does not.
    PLAN_WIRE_MALFORMED,
    PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
    PLAN_WIRE_UNSUPPORTED_PLAN_TAG,
    PLAN_WIRE_UNSUPPORTED_EXPR_TAG,
    PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY,
    PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET,
    PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
    PLAN_WIRE_UNSUPPORTED_UDF,
    PLAN_WIRE_UDF_NOT_DESCRIBABLE,
    PLAN_WIRE_UNSUPPORTED_TABLE_STATS,
    PLAN_WIRE_UNSUPPORTED_SCHEMALESS_SCAN,
    PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS,
    PLAN_WIRE_UNSUPPORTED_DTYPE,
    PLAN_WIRE_UNSUPPORTED_ARROW_TYPE,
    PLAN_WIRE_UNSUPPORTED_PARAM_TAG,
    PLAN_WIRE_UNSUPPORTED_WRITE_TARGET,
    PLAN_WIRE_WRITE_TARGET_DROPPED,
)

# THE STRUCTURAL GATE. Exported because a caller that receives plan bytes over
# a socket should be able to apply `PLAN_WIRE_MAX_BYTES` at the socket, before
# allocating — a size cap that can only be checked after the bytes are in
# memory has already lost the argument it exists to win.
from .plan_wire_admit import (
    plan_wire_admit,
    plan_wire_apparent_depth,
    plan_wire_envelope_prescan,
    PlanWireEnvelopePrescan,
    PlanWireVersionSet,
    PLAN_WIRE_MAX_DEPTH,
    PLAN_WIRE_MAX_NODES,
    PLAN_WIRE_MAX_BYTES,
    PLAN_WIRE_TOO_DEEP,
    PLAN_WIRE_TOO_MANY_NODES,
    PLAN_WIRE_TOO_LARGE,
    PLAN_WIRE_VERSION_MISMATCH,
    PLAN_WIRE_WRITE_TARGET_MIN_VERSION,
    PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED,
)

# ★ THE VALUE GATE. Exported for the same reason the structural one is: a caller
# that decodes a plan without coming through `komira_plan_endpoint` still
# needs to NAME the refusal it got, and a test needs to assert on the token
# rather than on prose. `plan_from_bytes` already runs it — no caller has to —
# but the tokens must be reachable, and so must the entry point, for a caller
# that builds a `LogicalPlan` from somewhere other than these bytes.
from .plan_wire_values import (
    plan_wire_check_values,
    PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
    PLAN_WIRE_UNRESOLVED_COLUMN,
    PLAN_WIRE_UNSUPPORTED_COL_IDX,
    PLAN_WIRE_INCONSISTENT_COUNT,
    PLAN_WIRE_NEGATIVE_COUNT,
    PLAN_WIRE_EMPTY_SORT_KEYS,
    PLAN_WIRE_UNCHECKED_VALUE_SITE,
    PLAN_WIRE_INCOMPARABLE_LITERAL,
    PLAN_WIRE_AGG_ARG_DROPPED,
)
