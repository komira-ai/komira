# =============================================================================
# komira_scan_resolver: the execution-time contract for a scan kind.
# =============================================================================
#
# `ScanMorselResolver` is what a scan kind implements so an engine can execute
# a plan leaf that names it; `ErasedScanMorselResolver` boxes one conformer
# behind a non-generic facade; `ScanMorselResolvers` is the per-context set,
# keyed by kind id, that refuses a duplicate kind and an unknown one by name.
#
# Depends on `komira_core` only. See `scan_morsel_resolver.mojo`.
# =============================================================================
