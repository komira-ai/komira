# =============================================================================
# iceberg_scan/local_file.mojo -- the local files a table scan reads
# =============================================================================
#
# This slice reads local files only (a bare path or a `file:` URI); every
# other scheme is refused before a byte is read (`table_ref.local_path_of`).
# The two helpers here are the whole of the package's file access: a probe for
# a directory and a whole-file read.
# =============================================================================

from async_rt.ops.waker_sink import NoopSink
from fs.local_fs import LocalFs


comptime _Fs = LocalFs[NoopSink]


def local_is_dir(path: String) raises -> Bool:
    """True iff `path` is a directory; raises when it does not exist."""
    var fs = _Fs.new()
    return fs.is_dir(path)


def read_local_file(path: String) raises -> List[UInt8]:
    """The whole file `path`, copied out of its mapping.

    Raises:
        The file system's error when the file is missing, unreadable or
        empty."""
    var fs = _Fs.new()
    var buf = fs.read_whole(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    var out = List[UInt8](capacity=len(span))
    out.extend(span)
    return out^
