# =============================================================================
# komira_scan_resolver: the execution-time contract for a scan kind.
# =============================================================================
#
# `ScanSourceResolver` is what a scan kind implements so an engine can execute
# a plan leaf that names it: it plans the splits one execution reads and opens
# a `SplitReader` per split. `ErasedScanSourceResolver` boxes one conformer
# behind a non-generic facade; `ScanSourceResolvers` is the per-context set,
# keyed by kind id, that refuses a duplicate kind and an unknown one by name.
# `drain_scan` is the bounded read over any conformer.
#
# Depends on the core packages only. See `scan_source_resolver.mojo`,
# `scan_split.mojo` and `drain_scan.mojo`.
# =============================================================================
