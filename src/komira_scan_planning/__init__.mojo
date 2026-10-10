# =============================================================================
# komira_scan_planning -- scan planning contracts
# =============================================================================
# This package holds scan planning code that sat in the filesystem layer only
# because of where it was first written:
#   * `reader_factory.mojo` -- the `ReaderFactory` trait a format implements
#     to open a reader over a file.
#   * `partition_predicate_split.mojo` -- the optimizer's split of a scan
#     filter into a partition-column part and a data-column part.
#   * `source_capability_config.mojo` -- the format-agnostic scan capability
#     bundle.
#   * `partition_pred_bridge.mojo` -- the mapping between the plan's
#     `PartitionPredicatePod` and the filesystem's `PartitionPredicate`.
#
# These are format and optimizer contracts. They are parked here, one layer
# above `komira_fs`, until the optimizer and parquet packages move; at that
# point they should follow their owners and this package can be dissolved.
#
# It depends on `komira_fs` and on the plan-expression types in
# the core packages (the core package that carries `plan.expr` today; it will
# change when the core split is cut over).
# =============================================================================
