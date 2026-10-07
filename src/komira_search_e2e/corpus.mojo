# =============================================================================
# komira_search_e2e/corpus.mojo
#   The deterministic corpus the end-to-end tests index: three splits of short
#   documents, ASCII and non-ASCII, each serialized by komira_search's
#   production `SearchSink`, plus the whole corpus as one split (the oracle
#   that does not depend on where the split boundaries fall).
# =============================================================================
#
# The analyzer is `AnalyzerConfig.text`: ASCII lowercase, then a fold of the
# Latin-1 Supplement and Latin Extended-A diacritics, then English stopwords.
# So `Zürich` and `zürich` both index as `zurich`, `café` and `cafe` both as
# `cafe`, and the CJK token `東京` is kept byte for byte (whitespace is the only
# token boundary). The matches below follow from that; the scan test asserts
# the exact documents per query, written by hand, as the oracle that does not
# run `SearchCore`. The ASCII queries `cafe` and `Zurich` match the same rows
# as `café` and `Zürich` only through the fold:
#
#   query     split 0      split 1      split 2       total
#   alpha     d0 d1        d0           d0            4
#   delta     d2           d1           d2            3
#   東京       d0                        d0            2
#   café      (none)       d0 (café)    d1 (cafe)     2
#   Zürich    d2 (Zürich)               d3 (zürich)   2
#   nowhere   (none)       (none)       (none)        0
#   (no query) 4           3            4             11
#
# Object keys and the manifest lineage are ASCII; the non-ASCII bytes live in
# the split bodies and in `_source`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink


comptime INDEX_NAME: String = "e2e_logs"
"""The index every test publishes."""

comptime TEXT_FIELD: String = "body"
"""The one analyzed text field."""

comptime NUM_SPLITS = 3


def text_analyzer() -> AnalyzerConfig:
    """The analyzer `SearchSink` indexes `body` with."""
    return AnalyzerConfig.text(TEXT_FIELD)


def split_bodies(split: Int) raises -> List[String]:
    """The `body` cells of split `split` (0, 1 or 2)."""
    if split == 0:
        return [
            String("alpha beta 東京"),
            String("alpha gamma"),
            String("Zürich lake delta"),
            String("beta beta epsilon"),
        ]
    if split == 1:
        return [
            String("café alpha"),
            String("gamma delta naïve"),
            String("the quick fox"),
        ]
    if split == 2:
        return [
            String("東京 tower alpha"),
            String("cafe beta"),
            String("delta delta delta"),
            String("omega zürich"),
        ]
    raise Error("corpus: no split " + String(split))


def split_sources(split: Int) raises -> List[String]:
    """The `_source` cells of split `split`: a tag naming the split and the
    document, some with non-ASCII bytes, so a row read back from disk is
    checked byte for byte."""
    var n = len(split_bodies(split))
    var out = List[String]()
    for d in range(n):
        var tag = String("s") + String(split) + String("-d") + String(d)
        if (split + d) % 2 == 0:
            tag += String(" ü東")
        out.append(tag^)
    return out^


def split_uuid(split: Int) -> Array[UInt8, 16]:
    """The 16-byte id of split `split`; distinct per split."""
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((split * 37 + i * 11 + 5) & 0xFF)
    return u^


def uuid_eq(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(TEXT_FIELD, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    return sb.build()


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def build_split(
    bodies: List[String], sources: List[String], uuid: Array[UInt8, 16]
) raises -> List[UInt8]:
    """Serialize one split with the production `SearchSink`."""
    var schema = _schema()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(_str_col(bodies))
    rb.add_column(_str_col(sources))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String(INDEX_NAME),
        String(TEXT_FIELD),
        uuid,
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def corpus_split(split: Int) raises -> List[UInt8]:
    """Split `split` of the corpus, serialized."""
    return build_split(split_bodies(split), split_sources(split), split_uuid(split))


def whole_corpus_split() raises -> List[UInt8]:
    """Every document of the corpus in ONE split, in split order."""
    var bodies = List[String]()
    var sources = List[String]()
    for s in range(NUM_SPLITS):
        var b = split_bodies(s)
        var src = split_sources(s)
        for d in range(len(b)):
            bodies.append(b[d])
            sources.append(src[d])
    return build_split(bodies, sources, split_uuid(99))


def split_doc_count(split: Int) raises -> Int:
    return len(split_bodies(split))
