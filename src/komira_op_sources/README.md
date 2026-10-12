# komira_op_sources

The sources of the engine's pipelines: the Arrow IPC stream and file readers (in-memory, codec-reporting and memory-mapped) with their dictionary cache, the source that streams one or several in-memory record batches as morsels (shared claim cursor, optional work stealing), and the source that serves a registered intermediate result to a later stage. The per-batch IPC decoding is `komira_arrow_ipc`'s; source statistics are `komira_plan_stats.source_statistics.SourceStatistics`. Its switches are constructor arguments; it reads no environment.
