# =============================================================================
# sink_variant_tags.mojo -- the 16 `SinkVariant` arm-lookup tags, and NOTHING
# ELSE. Zero imports, by construction.
# =============================================================================
#
# WHY THIS FILE EXISTS: A TAG IS AN INTEGER; NAMING IT SHOULD NOT PULL IN THE
# WRITE STACK.
#
# These 16 `comptime UInt8` values belong semantically beside the `SinkVariant`
# struct that dispatches on them. Declared there, they made every module that
# wanted only the INTEGERS (a plan cache that names no sink type and uses the
# tags only to widen a hash) import the whole write stack behind the sink
# struct: the file sink, the arrow codec/format vocabulary, the dispatcher,
# the cancellation token and the no-op sink.
#
# Keeping the tags here means a translation unit that names `plan_compile_cache`
# and not `sink_variant` does not reach the parquet reader, the filesystem
# ladder, the dispatcher or the engine runtime. This is a closure fact about
# elaboration, not a wall-clock promise: every file of a package lands in one
# `.mojoc`, so an intra-package split moves no build-invalidation number.
#
# WHY THE TAGS DO NOT MOVE DOWN TO THE SHARED CORE. The write-format and
# write-compression enums moved to the core precisely because they cross the
# wire. The `SINK_VARIANT_FILE_*` tags deliberately did not: they are the
# RECEIVER'S ARM LOOKUP, and the arm one resolves to is the receiver's own
# business and may differ between builds. Registering them in anything the plan
# wire codec imports would publish an append-only, never-renumberable wire
# identity for an implementation detail.
#
# ONE SOURCE OF TRUTH. These sixteen values are declared HERE and imported
# everywhere else, including by the sink variant itself. Do not re-declare a tag
# at a consumer "to avoid the import": a duplicated integer that drifts
# silently mis-routes a write to the wrong arm, which is a wrong FILE FORMAT on
# disk with no diagnostic anywhere.
# =============================================================================



# =============================================================================
# Tag enum — UInt8 discriminator (mirrors source_variant.mojo alias scheme).
# =============================================================================

comptime SINK_VARIANT_FILE_PARQUET_SNAPPY: UInt8 = 0
comptime SINK_VARIANT_FILE_PARQUET_ZSTD: UInt8 = 1
comptime SINK_VARIANT_FILE_CSV: UInt8 = 2
# Added with the full extension cascade for `file_sink(path)`.
comptime SINK_VARIANT_FILE_PARQUET_UNCOMPRESSED: UInt8 = 3
comptime SINK_VARIANT_FILE_PARQUET_GZIP: UInt8 = 4
comptime SINK_VARIANT_FILE_JSONL: UInt8 = 5
comptime SINK_VARIANT_FILE_JSONL_GZIP: UInt8 = 6
# Arrow IPC stream arms (tag IDs 7-9). Stream format only; the file format
# (footer + ARROW1 magic) is a separate arm.
comptime SINK_VARIANT_FILE_ARROW_UNCOMPRESSED: UInt8 = 7
comptime SINK_VARIANT_FILE_ARROW_LZ4_FRAME: UInt8 = 8
comptime SINK_VARIANT_FILE_ARROW_ZSTD: UInt8 = 9
# CSV compressed arms (tag IDs 10-12).
comptime SINK_VARIANT_FILE_CSV_GZIP: UInt8 = 10
comptime SINK_VARIANT_FILE_CSV_ZSTD: UInt8 = 11
comptime SINK_VARIANT_FILE_CSV_LZ4: UInt8 = 12
# Tag IDs 13-14. JSONL already had `.jsonl.gz` (tag 6); these restore parity
# with CSV's 3-codec compressed coverage (.jsonl.zst / .jsonl.lz4).
comptime SINK_VARIANT_FILE_JSONL_ZSTD: UInt8 = 13
comptime SINK_VARIANT_FILE_JSONL_LZ4: UInt8 = 14
# Tag ID 15. The 5th Parquet codec arm (LZ4_RAW, Parquet codec id 7). Mirrors
# the Parquet[Zstd[3]] / Parquet[Gzip[6]] arms exactly.
comptime SINK_VARIANT_FILE_PARQUET_LZ4: UInt8 = 15
