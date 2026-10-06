# =============================================================================
# The Hive tree: each partition's rows through each of the four writers.
# =============================================================================
#
#   <root>/city=Zürich/part-0.{avro,csv,jsonl,orc}
#   <root>/city=Oslo/part-0.{avro,csv,jsonl,orc}
#
# The directory name carries the partition value as raw UTF-8 bytes (no
# %-escape), the layout Spark and Hive write. Every writer is called through
# its public entry point with default options:
#   ORC   `write_orc_file` with `OrcWriterOptions.default()` (ZSTD);
#   Avro  `write_avro_file` with `AvroWriterOptions()` (null codec);
#   JSONL `write_batch_jsonl_direct` into a buffer, written through LocalFs;
#   CSV   `CsvSink`: `init_sink`, `accept_batch`, `finish` (header row, `,`).
# =============================================================================

from std.os import makedirs

from komira_async.ops.waker_sink import NoopSink
from komira_avro import AvroWriterOptions, write_avro_file
from komira_csv.csv_sink import CsvSink
from komira_fs.file_system import WriteMode
from komira_fs.local_fs import LocalFs
from komira_jsonl.json_writer import write_batch_jsonl_direct
from komira_orc import OrcWriterOptions, write_orc_file

from .dataset import batch_for_city, cities


def format_exts() -> List[String]:
    """The file extensions written per partition, in byte order."""
    var out = List[String]()
    out.append(String("avro"))
    out.append(String("csv"))
    out.append(String("jsonl"))
    out.append(String("orc"))
    return out^


def partition_dir(root: String, city: String) -> String:
    return root + "/city=" + city


def file_path(root: String, city: String, ext: String) -> String:
    return partition_dir(root, city) + "/part-0." + ext


def write_file_bytes(path: String, bytes: List[UInt8]) raises:
    """Write `bytes` to `path` through `LocalFs` (created or truncated)."""
    var fs = LocalFs[NoopSink].new()
    var f = fs.open_write(path, WriteMode.create_truncate())
    var n = fs.write_at(f, Span(bytes))
    fs.close_write(f^)
    if Int(n) != len(bytes):
        raise Error(
            "write_file_bytes: short write of " + path + ": " + String(n)
        )


def _write_csv(path: String, city: String) raises:
    var rb = batch_for_city(city)
    var schema = rb.schema.copy()
    var sink = CsvSink(path)
    sink.init_sink(schema)
    sink.accept_batch(rb^)
    sink.finish()


def write_hive_tree(root: String) raises:
    """Write every partition's rows through the four writers under `root`
    (created if missing). Existing files are truncated."""
    makedirs(root, exist_ok=True)
    var cs = cities()
    for ci in range(len(cs)):
        var city = cs[ci].copy()
        makedirs(partition_dir(root, city), exist_ok=True)

        var rb = batch_for_city(city)
        write_orc_file(rb, file_path(root, city, "orc"), OrcWriterOptions.default())
        write_avro_file(rb, file_path(root, city, "avro"), AvroWriterOptions())
        var jsonl = List[UInt8]()
        write_batch_jsonl_direct(jsonl, rb)
        write_file_bytes(file_path(root, city, "jsonl"), jsonl)
        _write_csv(file_path(root, city, "csv"), city)
