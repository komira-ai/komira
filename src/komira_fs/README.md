# komira_fs

The file-system layer under komira's sources and sinks, as traits plus the
local implementation:

- `FileSystem` (one implementation per storage backend) and `FileFormat`
  (one per file format); a source is generic over the pair. `ByteRange` and
  `FooterRegion` are the values they exchange; `ReadableHandle` and
  `WritableHandle` are the byte-stream handles over a file or a buffer.
- `LocalFs[S]`, the local-disk `FileSystem`: listing (recursive and one
  level), `is_dir` and `file_size` probes, positional reads served from a
  memory map, footer reads, and positional and appending writes through
  `write(2)`, all synchronous. `S` is the komira_async waker-sink type the
  `FileSystem` trait is generic over.
- Path discovery: the glob engine (`*`, `?`, `[a-z]`, POSIX classes, `**`
  across directories, and `{a,b}` brace alternation), splitting a pattern
  into the static prefix a listing can use and the residual matched
  client-side, eager and pruned Hive-partition discovery, and the partition
  value codec (`key=value` directory segments, percent-escaped, with
  `__HIVE_DEFAULT_PARTITION__` for null).

The object-store file systems live in their own packages (for example
`komira_objectstore_s3`). This package does not read any file format itself.

## Examples

Globs, as discovery uses them:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_fs.glob import brace_expand, glob_match_path, has_glob, split_static_prefix

assert_true(has_glob("data/*.parquet"))
assert_false(has_glob("data/year=2026/part-0.parquet"))  # `=` is not a glob character

var split = split_static_prefix("data/year=*/part-*.parquet")
assert_equal(split[0], "data/")                  # what a listing can ask for
assert_equal(split[1], "year=*/part-*.parquet")  # matched against each result

assert_true(glob_match_path("data/**/*.parquet", "data/a/b/part-0.parquet"))
assert_true(glob_match_path("part-[0-9].csv", "part-7.csv"))
assert_false(glob_match_path("*.parquet", "part-0.csv"))

var alts = brace_expand("{logs,metrics}/{a,b}.json")
assert_equal(len(alts), 4)
assert_equal(alts[0], "logs/a.json")
assert_equal(alts[3], "metrics/b.json")
```

Hive partition directories: split a path into keys and raw values, and decode
or encode a value:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_fs.partition_codec import encode_partition_value, parse_key_value_segments
from komira_fs.partition_codec import parse_partition_value

var keys = List[String]()
var values = List[String]()
parse_key_value_segments("/warehouse/sales/region=eu%20west/day=2026-11-04/part-0.parquet", keys, values)
assert_equal(len(keys), 2)
assert_equal(keys[0], "region")
assert_equal(values[0], "eu%20west")  # raw, as on disk
assert_equal(parse_partition_value(values[0], ArrowType.STRING), "eu west")
assert_equal(keys[1], "day")

assert_equal(encode_partition_value("a/b c", ArrowType.STRING), "a%2Fb%20c")
assert_equal(encode_partition_value("", ArrowType.STRING), "__HIVE_DEFAULT_PARTITION__")  # null
assert_equal(parse_partition_value("__HIVE_DEFAULT_PARTITION__", ArrowType.STRING), "")
```

The local file system, in a temporary directory the example creates: write a
file, probe it, read a range back, list the directory, then delete:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.tempfile import mkdtemp
from komira_async.ops.waker_sink import NoopSink
from komira_fs.file_system import WriteMode
from komira_fs.local_fs import LocalFs

var fs = LocalFs[NoopSink].new()
var root = mkdtemp(prefix="komira_fs_readme_")
var path = root + "/hello.txt"

var wf = fs.open_write(path, WriteMode.create_truncate())
assert_equal(fs.write_at(wf, "hello, komira".as_bytes()), Int64(13))
fs.close_write(wf^)

assert_true(fs.is_dir(root))
assert_false(fs.is_dir(path))
assert_equal(fs.file_size(path), 13)

var file = fs.open(path)
var buf = fs.read_at(file, Int64(7), Int64(6))  # bytes [7, 13)
assert_equal(buf.len(), 6)
var view = buf.view_range_ro(0, 6)
var got = view.into_span()
var want = "komira".as_bytes()
for i in range(6):
    assert_equal(got[i], want[i])

var listed = fs.list(root)
assert_equal(len(listed), 1)
assert_true(listed[0].endswith("hello.txt"))

fs.delete(path)
fs.delete(root)  # remove(3) takes an empty directory too
var message = String()
try:
    _ = fs.is_dir(root)
except e:
    message = String(e)
assert_true("path not found" in message)
```
