# komira_core.io — process-level I/O primitives.
#
# Currently houses:
#   * mmap_region.mojo — POSIX `mmap(2)`-backed read-only file mapping.
#   * chunked_write.mojo — `FileHandle.write` >2 GB bug workaround.
#     EVERY call site that hands a String/Span/List whose length COULD
#     exceed 2 GB to `FileHandle.write` MUST route through
#     `write_chunked` / `write_chunked_string`, NOT call
#     `FileHandle.write` directly.
#
# This is a leaf submodule of `komira_core`. No dependencies on other
# `komira_core.*` submodules — keeps the dep graph clean.
