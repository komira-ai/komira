"""`komira_op_sources` -- the sources of the engine's pipelines.

The Arrow IPC stream reader and file reader with their dictionary cache (the
file reader has an in-memory path and a memory-mapped one), the source that
streams one or several in-memory record batches as morsels, and the source that
serves a registered intermediate result to a later stage. Anything that turns
bytes or batches into morsels lives here; the operators that consume them are in
the packages above.

It depends on the core packages (`komira_arrow`, `komira_arrow_ipc`,
`komira_buffer`, ...), `komira_async`, `komira_morsel` and `komira_plan_stats`
(for `SourceStatistics`), and on no operator package or the engine runtime.

Modules: `arrow_stream_reader`, `arrow_file_reader` (in-memory File and
auto-detect), `arrow_file_reader_codec` (codec-reporting and strict readers),
`arrow_file_reader_mmap` (memory-mapped path reader), `ipc_stream_frames`
(package-private frame helpers), `ipc_dict_cache`, `batch_morsel_source`,
`cte_morsel_source`.

Public API: import directly from sub-modules. No facade.
"""
