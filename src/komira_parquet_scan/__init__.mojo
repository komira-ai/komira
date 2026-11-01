"""`komira_parquet_scan`: the engine side of the Parquet scan.

The per-file reader a scan's morsel source drives (`parquet_reader`, built by
`parquet_reader_factory`), with its page-index-pruned decodes, its
row-selective decode (`payload_sel_decode`), the dictionary-codes feed of a
grouped aggregate (`parquet_codes_feed`), the conjunct-by-conjunct filter
decode (`staged_filter`), the dictionary-select arms of the sub-row-group
aggregate (`subrg_filter_gather`), the top-N row-group bounds
(`topn_rg_bounds`), the shared pool of parked sub-morsels
(`parked_morsel_share`) and the row-group prune counters
(`rg_prune_counter`).

It builds on the reader core (`komira_parquet`), the morsel layer
(`komira_morsel`), the batch evaluator (`komira_batch_eval`) and the scan
planning traits (`komira_scan_planning`), and on no operator package.

Public API: import from the modules. The package root re-exports nothing.
"""
