"""`komira_search_e2e` -- a search index published to the local filesystem
and read back cold, through the catalog and the `komira.search.index` scan.

This package exists for its tests. Its sources are the shared fixture:

- `corpus.mojo`: three splits of short documents with ASCII and non-ASCII
  terms (`Zürich`, `café`, `東京`), serialized by `SearchSink`, the same
  documents as one whole-corpus split, and the analyzer they index with.
- `catalog.mojo`: publishing a split through `SearchMetastore` (the split
  object first, then the summary), cold metastore handles, the caller's half
  of a reap (only for a tombstoned chunk), and `MetastoreSearchCatalog`, a
  `SearchIndexCatalog` that reports `SearchMetastore.generation()` (it moves
  on every publish, retire and reap) and serves the split set it recorded for
  each generation, so a scan resolved before a retire reads what it planned.
- `rows.mojo`: resolving and draining a live scan into rows, and the
  baseline rows `SearchCore` returns for in-memory split bytes.

The tests (`tests/`) run over `LocalFsConditionalStore` rooted in the run's
`TEST_TMPDIR`: two handles with stale cached heads interleaving their
publishes (each loss is the store's 412 from its existence probe; the
`O_EXCL` loss of a truly simultaneous create is left to komira_objectstore's
own tests), a cold reader of the published lineage, the scan compared with
`SearchCore` and with a hand-written match table for several queries, and
retires and reaps read back cold. Nothing here is
shipped (`conda = False`).
"""

from .corpus import (
    INDEX_NAME,
    TEXT_FIELD,
    NUM_SPLITS,
    text_analyzer,
    split_bodies,
    split_sources,
    split_uuid,
    uuid_eq,
    build_split,
    corpus_split,
    whole_corpus_split,
    split_doc_count,
)
from .catalog import (
    lineage_prefix,
    split_object_key,
    open_metastore,
    cold_metastore,
    publish_split,
    reap_retired_split,
    live_split_bytes,
    catalog_snapshot_key,
    MetastoreSearchCatalog,
)
from .rows import (
    ScanRows,
    hit_row,
    hit_source,
    resolve_scan,
    drain_rows,
    scan_rows,
    core_rows,
    core_sources,
    baseline_rows,
    sorted_strings,
)
