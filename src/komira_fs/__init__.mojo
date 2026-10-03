# =============================================================================
# komira_fs — FileSystem + FileFormat trait surface
# =============================================================================
# This package provides the orthogonal-traits substrate for sources and
# sinks: a `FileSystem` trait (one impl per storage backend — Local,
# S3, HDFS, GCS, Azure) and a `FileFormat` trait (one impl per file format
# — Parquet, Avro, JSON, CSV). Concrete sources monomorphize over the
# (FS, FMT) pair and compose via URI-scheme dispatch.
#
# Core files:
#   * `byte_range.mojo` — small ByteRange POD shared by FS + Format.
#   * `file_system.mojo` — `FileSystem` trait shape (validate Mojo 0.26.3
#     elaboration of associated-type alias `S: WakerSink` + parametric
#     return types involving Self.S).
#   * `local_fs.mojo` — `LocalFile` + `LocalFs[S]` impl.
#   * `file_format.mojo` — `FileFormat` trait shape (validate parametric
#     methods over `FS: FileSystem` on a trait body).
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * ZERO new wildcard origins.
#   * Trait surface exposes only typed values + IoOp value handles.
# =============================================================================
