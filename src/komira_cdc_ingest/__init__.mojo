"""komira_cdc_ingest — change-data-capture ingest into an Iceberg table (apply, position, driver).

This package ties a change-stream reader to the Iceberg write path. It holds the
provider-agnostic apply logic, the crash-safe per-shard position tracking (the
position is stamped into the Iceberg snapshot summary, so there is no separate
checkpoint store), and the multi-shard tail, apply and commit driver loop. A
caller supplies a concrete listener and a concrete Iceberg table (an object store
and a location).

It is testable end to end over a scripted listener and an on-disk Iceberg store,
with no cloud and no network. A provider's listener lives in its own package and
conforms to the traits in `komira_snapshotter`; this package names only
`komira_snapshotter`, `komira_iceberg` and `komira_objectstore`.
"""

from .cdc_apply import (
    ApplyStats,
    CdcApplyConfig,
    apply_batch,
)

from .cdc_position import (
    CDC_SUMMARY_KEY_PREFIX,
    ShardPositions,
    derive_positions_from_table,
    seq_gt,
)

from .cdc_ingest_driver import (
    PassStats,
    run_ingest_pass,
    run_ingest_loop,
)
