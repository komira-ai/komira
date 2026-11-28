"""komira.pl's sinks, `sink_csv`, `sink_parquet` and `sink_ndjson`, with no
library: frames are scans of a stand-in session whose file schemas are written
here and whose plan door records the envelopes it is given and answers one row
of `Count`, as the engine answers a write.

- test_each_sink_hands_the_engine_the_frames_plan_under_its_write_target: each
  sink runs the plan once, and its envelope is the envelope `collect()` hands
  the engine (the same plan, of a filtered, computed, sorted frame) with a
  write target: the absolute path, the sink's format and polars' default codec
  (uncompressed CSV and NDJSON, zstd Parquet); each returns None;
- test_compression_names_the_codec_and_the_extension_is_not_read: gzip and zstd
  for CSV and NDJSON, every Parquet codec, and a `.csv.gz` path written
  uncompressed by default;
- test_a_path_is_made_absolute_at_the_call: a relative path against the working
  directory of the call, a `pathlib.Path`, and `~`;
- test_the_taken_defaults_write_what_the_defaults_write: each keyword passed at
  the value komira writes (`null_value=""`, `maintain_order=False` too) hands
  the engine the same bytes as the call without it;
- test_refusals_name_the_argument_and_run_nothing: every value komira does not
  write, by exact class and message, and a keyword polars has and the sink
  does not (Python's TypeError naming it); the session runs nothing;
- test_the_eager_write_names_point_to_the_sinks: `write_csv`, `write_parquet`
  and `write_ndjson`, polars' eager DataFrame's, raise AttributeError naming
  the sink to call.

The test loads no library and is of the `pl/` family (python/tests/BUCK): it
runs on each supported minor, with the generated plan modules, protobuf 7.36.2
and pyarrow.

    test_pl_sink.py
"""

import io
import os
import pathlib
import tempfile

import pyarrow as pa

import komira
import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._plan._wire import arrow_id, field, pb, vocab

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "sink_source.parquet")
TYPES = [("id", "int64"), ("x", "float64"), ("s", "string")]


class StandIn(Session):
    """A session with no library: the schema of PATH, plans recorded, and
    every plan answered with one row of Count."""

    def __init__(self):
        self.ran = []

    def _parquet_schema(self, path):
        fields = [field(n, arrow_id(t), True) for n, t in TYPES]
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        table = pa.table({"Count": pa.array([3], pa.int64())})
        return komira.Result(pa.RecordBatchReader.from_batches(table.schema, table.to_batches()))

    def close(self):
        pass


def setup():
    s = StandIn()
    return s, kpl.scan_parquet(PATH, session=s)


def composed(lf):
    return lf.filter(kpl.col("id") > 1).with_columns((kpl.col("x") * 2).alias("y")).sort("id", descending=True)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    assert str(e) == message, str(e)


def envelope(plan):
    return pb.WirePlanEnvelope.FromString(plan)


def last_target(s):
    target = envelope(s.ran[-1]).write_target
    return target.path, target.format, target.codec


OUT = os.path.join(tempfile.gettempdir(), "sink_out")


def test_each_sink_hands_the_engine_the_frames_plan_under_its_write_target():
    s, lf = setup()
    frame = composed(lf)
    frame.collect()
    collected = envelope(s.ran[-1])
    assert not collected.HasField("write_target")
    cases = [
        (frame.sink_csv, OUT + ".csv", vocab.WFMT_CSV, vocab.WCOMP_UNCOMPRESSED),
        (frame.sink_parquet, OUT + ".parquet", vocab.WFMT_PARQUET, vocab.WCOMP_ZSTD),
        (frame.sink_ndjson, OUT + ".jsonl", vocab.WFMT_JSONL, vocab.WCOMP_UNCOMPRESSED),
    ]
    for sink, path, fmt, codec in cases:
        before = len(s.ran)
        assert sink(path) is None
        assert len(s.ran) == before + 1, sink.__name__
        sent = envelope(s.ran[-1])
        assert (sent.write_target.path, sent.write_target.format, sent.write_target.codec) == (path, fmt, codec)
        assert sent.plan == collected.plan, sink.__name__
        assert list(sent.udfs) == list(collected.udfs), sink.__name__


def test_compression_names_the_codec_and_the_extension_is_not_read():
    s, lf = setup()
    text = [("gzip", vocab.WCOMP_GZIP), ("zstd", vocab.WCOMP_ZSTD), ("uncompressed", vocab.WCOMP_UNCOMPRESSED)]
    for name, codec in text:
        lf.sink_csv(OUT + ".csv", compression=name)
        assert last_target(s) == (OUT + ".csv", vocab.WFMT_CSV, codec), name
        lf.sink_ndjson(OUT + ".jsonl", compression=name)
        assert last_target(s) == (OUT + ".jsonl", vocab.WFMT_JSONL, codec), name
    parquet = [
        ("zstd", vocab.WCOMP_ZSTD),
        ("snappy", vocab.WCOMP_SNAPPY),
        ("gzip", vocab.WCOMP_GZIP),
        ("lz4", vocab.WCOMP_LZ4),
        ("uncompressed", vocab.WCOMP_UNCOMPRESSED),
    ]
    for name, codec in parquet:
        lf.sink_parquet(OUT + ".parquet", compression=name)
        assert last_target(s) == (OUT + ".parquet", vocab.WFMT_PARQUET, codec), name
    # The verb and the argument choose; the name does not.
    lf.sink_csv(OUT + ".csv.gz")
    assert last_target(s) == (OUT + ".csv.gz", vocab.WFMT_CSV, vocab.WCOMP_UNCOMPRESSED)
    lf.sink_parquet(OUT + ".csv")
    assert last_target(s) == (OUT + ".csv", vocab.WFMT_PARQUET, vocab.WCOMP_ZSTD)


def test_a_path_is_made_absolute_at_the_call():
    s, lf = setup()
    with tempfile.TemporaryDirectory() as work:
        cwd = os.getcwd()
        try:
            os.chdir(work)
            lf.sink_csv("rel.csv")
            here = os.path.join(os.getcwd(), "rel.csv")
        finally:
            os.chdir(cwd)
        assert last_target(s)[0] == here, last_target(s)
        assert os.listdir(work) == []
    lf.sink_parquet(pathlib.Path(OUT) / "p.parquet")
    assert last_target(s)[0] == os.path.join(OUT, "p.parquet")
    lf.sink_ndjson("~/n.jsonl")
    assert last_target(s)[0] == os.path.join(os.path.expanduser("~"), "n.jsonl")


def test_the_taken_defaults_write_what_the_defaults_write():
    s, lf = setup()
    path = OUT + ".csv"
    lf.sink_csv(path)
    plain = s.ran[-1]
    taken = [
        dict(include_header=True),
        dict(separator=","),
        dict(line_terminator="\n"),
        dict(quote_char='"'),
        dict(null_value=None),
        dict(null_value=""),
        dict(include_bom=False),
        dict(compression="uncompressed"),
        dict(compression_level=None),
        dict(maintain_order=True),
        dict(maintain_order=False),
        dict(mkdir=False),
        dict(lazy=False),
    ]
    for kwargs in taken:
        assert lf.sink_csv(path, **kwargs) is None
        assert s.ran[-1] == plain, kwargs
    lf.sink_parquet(OUT + ".parquet")
    plain = s.ran[-1]
    for kwargs in (dict(compression="zstd"), dict(maintain_order=False), dict(compression_level=None)):
        lf.sink_parquet(OUT + ".parquet", **kwargs)
        assert s.ran[-1] == plain, kwargs
    lf.sink_ndjson(OUT + ".jsonl")
    plain = s.ran[-1]
    for kwargs in (dict(compression="uncompressed"), dict(maintain_order=False), dict(mkdir=False)):
        lf.sink_ndjson(OUT + ".jsonl", **kwargs)
        assert s.ran[-1] == plain, kwargs


def test_refusals_name_the_argument_and_run_nothing():
    s, lf = setup()
    csv = OUT + ".csv"
    comma = "komira writes ',' between cells"
    text_codecs = "komira writes 'uncompressed', 'gzip' or 'zstd'"
    file_object = "komira writes to a file path, not into a file object"
    cases = [
        (lambda: lf.sink_csv(csv, separator=";"), UnsupportedOperation,
         f"sink_csv(separator=';') is not supported: {comma}"),
        (lambda: lf.sink_csv(csv, separator="\t"), UnsupportedOperation,
         f"sink_csv(separator='\\t') is not supported: {comma}"),
        (lambda: lf.sink_csv(csv, include_header=False), UnsupportedOperation,
         "sink_csv(include_header=False) is not supported: komira always writes the header line"),
        (lambda: lf.sink_csv(csv, line_terminator="\r\n"), UnsupportedOperation,
         "sink_csv(line_terminator='\\r\\n') is not supported: komira ends each line with '\\n'"),
        (lambda: lf.sink_csv(csv, quote_char="'"), UnsupportedOperation,
         "sink_csv(quote_char=\"'\") is not supported: komira quotes a cell with '\"'"),
        (lambda: lf.sink_csv(csv, null_value="NA"), UnsupportedOperation,
         "sink_csv(null_value='NA') is not supported: komira writes NULL as an empty cell"),
        (lambda: lf.sink_csv(csv, include_bom=True), UnsupportedOperation,
         "sink_csv(include_bom=True) is not supported: komira writes no byte order mark"),
        (lambda: lf.sink_csv(csv, compression="bz2"), UnsupportedOperation,
         f"sink_csv(compression='bz2') is not supported: {text_codecs}"),
        (lambda: lf.sink_csv(csv, compression="snappy"), UnsupportedOperation,
         f"sink_csv(compression='snappy') is not supported: {text_codecs}"),
        (lambda: lf.sink_ndjson(csv, compression="lz4"), UnsupportedOperation,
         f"sink_ndjson(compression='lz4') is not supported: {text_codecs}"),
        (lambda: lf.sink_parquet(csv, compression="brotli"), UnsupportedOperation,
         "sink_parquet(compression='brotli') is not supported: "
         "komira writes 'zstd', 'snappy', 'gzip', 'lz4' or 'uncompressed'"),
        (lambda: lf.sink_csv(csv, compression_level=3), UnsupportedOperation,
         "sink_csv(compression_level=3) is not supported: komira writes each codec at its default level"),
        (lambda: lf.sink_parquet(csv, compression_level=9), UnsupportedOperation,
         "sink_parquet(compression_level=9) is not supported: komira writes each codec at its default level"),
        (lambda: lf.sink_ndjson(csv, mkdir=True), UnsupportedOperation,
         "sink_ndjson(mkdir=True) is not supported: komira writes into a directory that exists"),
        (lambda: lf.sink_csv(csv, lazy=True), UnsupportedOperation,
         "sink_csv(lazy=True) is not supported: komira writes the file at the call and returns None"),
        (lambda: lf.sink_csv(io.BytesIO()), UnsupportedOperation,
         f"sink_csv() of a BytesIO is not supported: {file_object}"),
        (lambda: lf.sink_ndjson(io.StringIO()), UnsupportedOperation,
         f"sink_ndjson() of a StringIO is not supported: {file_object}"),
        (lambda: lf.sink_csv(None), TypeError, "path must be a str or os.PathLike[str], not NoneType"),
        (lambda: lf.sink_parquet(3), TypeError, "path must be a str or os.PathLike[str], not int"),
        (lambda: lf.sink_csv(csv, compression=None), TypeError, "sink_csv compression must be a str, not NoneType"),
        (lambda: lf.sink_parquet(csv, compression=None), TypeError,
         "sink_parquet compression must be a str, not NoneType"),
        (lambda: lf.sink_csv(csv, include_header=1), TypeError, "sink_csv include_header must be a bool, not int"),
        (lambda: lf.sink_csv(csv, include_bom=0), TypeError, "sink_csv include_bom must be a bool, not int"),
        (lambda: lf.sink_parquet(csv, maintain_order="yes"), TypeError,
         "sink_parquet maintain_order must be a bool, not str"),
        (lambda: lf.sink_ndjson(csv, mkdir=None), TypeError, "sink_ndjson mkdir must be a bool, not NoneType"),
        (lambda: lf.sink_csv(csv, lazy=1), TypeError, "sink_csv lazy must be a bool, not int"),
    ]
    for call, cls, message in cases:
        refused(call, cls, message)
    assert s.ran == []
    # A keyword polars has and the sink does not take is Python's own error.
    e = raised(lambda: lf.sink_csv(csv, batch_size=10))
    assert type(e) is TypeError and "batch_size" in str(e), repr(e)
    assert s.ran == []


def test_the_eager_write_names_point_to_the_sinks():
    _, lf = setup()
    for name, sink in (("write_csv", "sink_csv"), ("write_parquet", "sink_parquet"), ("write_ndjson", "sink_ndjson")):
        refused(
            lambda: getattr(lf, name),
            AttributeError,
            f".{name}() is a method of polars' eager DataFrame, which komira.pl does not have: "
            f"a LazyFrame writes its rows with .{sink}(path)",
        )
        assert not hasattr(lf, name)
        assert callable(getattr(lf, sink))


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_sink: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
