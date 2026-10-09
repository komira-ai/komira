# komira_search

The core of a full-text search engine, in memory and without I/O: it turns text
into a split (an immutable byte image holding an inverted index, a term
dictionary, a compressed store of each document's `_source`, and optional fast
fields), and answers queries over one split.

- Analysis: `analyze_text(text, AnalyzerConfig)` splits on whitespace, lowercases,
  folds ASCII accents and drops a 33-word English stopword set
  (`AnalyzerConfig.text(field)`). Indexing and querying go through the same
  normalizer, so a query term matches exactly what was indexed. Keyword fields
  are not tokenized; analyzing one raises.
- Writing a split: `InvertedIndexBuilder` (term to ascending document ids and
  term frequencies), `TermDictBuilder` / `TermDictionary`, `DocStoreBuilder`
  (LZ4-compressed `_source` blocks), the fast-field builders, and
  `serialize_split`, which returns the split as `List[UInt8]`. `IndexCore` and
  `SearchSink` do the same from Arrow record batches.
- Reading: `SearchCore(split_bytes)` parses a split once; `search(QueryIR)` runs
  a `match` over one text field: every query term (deduplicated) adds its BM25
  contribution, and the top `top_k` hits come back as a record batch of
  `_score` (Float64), `_id` (Int64, the split-local document id) and `_source`
  (string). A split indexes one text field (`SplitView.field_name`); a query
  whose `field_name` differs is refused as `SEARCH_QUERY_FIELD_MISMATCH`.
  `QueryIR` also carries fast-field filters, sorts, paging and
  aggregations (`AggSpec`), and `match_all` for a scan without a query.
- Scoring: `bm25_idf`, `bm25_tf_component` and `bm25_score_contribution` with
  `Bm25Params` (default `k1 = 1.2`, `b = 0.75`, the modern form without the
  `(k1 + 1)` numerator; `legacy=True` restores it).

It does not store or fetch splits, keep a catalog of them, or serve HTTP:
`komira_search_catalog` records which splits are live and `komira_search_scan`
reads an index as a scan. Phrase queries are not supported (token positions are
not indexed).

## Examples

The analyzer: stopwords dropped, case folded. A keyword field is not
analyzed:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_search import AnalyzerConfig, analyze_text

var field = analyze_text("The Cafe is OPEN today", AnalyzerConfig.text("body"))
assert_equal(field.len(), 3)
assert_equal(field.tokens[0].term, "cafe")
assert_equal(field.tokens[1].term, "open")
assert_equal(field.tokens[2].term, "today")

var refused = False
try:
    _ = analyze_text("Some Status", AnalyzerConfig.keyword("status"))
except e:
    refused = String(e).byte_length() > 0
assert_true(refused)
```

BM25 is plain arithmetic: the IDF is `ln(1 + (N - n + 0.5) / (n + 0.5))`, and
with `b = 0` a term's contribution is `idf * tf / (tf + k1)`:

<!-- mojo-hidden from std.testing import assert_almost_equal, assert_true -->
```mojo
from std.math import log
from komira_search import Bm25Params, bm25_idf, bm25_score_contribution

var idf = bm25_idf(2, 10)  # the term is in 2 of 10 documents
assert_almost_equal(idf, log(1.0 + 8.5 / 2.5))
var no_length_norm = Bm25Params(b=0.0)
assert_almost_equal(bm25_score_contribution(idf, 3, no_length_norm), idf * 3.0 / 4.2)
# Rarer terms weigh more.
assert_true(bm25_idf(1, 10) > bm25_idf(5, 10))
```

Index three documents into a split, then search it. The document that says "fox"
twice ranks first, and each hit carries its `_source`:

<!-- mojo-hidden from std.testing import assert_equal, assert_almost_equal -->
```mojo
from komira_search import AnalyzerConfig, DocStoreBuilder, InvertedIndexBuilder, TermDictBuilder
from komira_search import Bm25Params, QueryIR, SearchCore, analyze_text, bm25_idf
from komira_search import bm25_score_contribution, serialize_split


def build_split(texts: List[String]) raises -> List[UInt8]:
    var config = AnalyzerConfig.text("body")
    var index = InvertedIndexBuilder.create("body")
    var sources = DocStoreBuilder()
    for i in range(len(texts)):
        index.add_document(i, analyze_text(texts[i], config))
        sources.append(texts[i].as_bytes())
    var finalized = index.finalize()
    var terms = TermDictBuilder.build_from_finalized(finalized)
    var n = len(texts)
    return serialize_split(
        finalized, terms^, sources, "body", Array[UInt8, 16](fill=UInt8(1)), 0, n - 1, n
    )


var texts: List[String] = ["The quick brown fox", "A lazy dog", "Fox and fox cubs"]
var core = SearchCore(build_split(texts))
assert_equal(core.doc_count(), 3)

var result = core.search(QueryIR("body", "FOX", 10, AnalyzerConfig.text("body")))
var hits = result.take_batch()
assert_equal(hits.num_rows(), 2)
assert_equal(Int(hits.column_at(1).as_primitive[DType.int64]().get(0)), 2)
assert_equal(Int(hits.column_at(1).as_primitive[DType.int64]().get(1)), 0)
assert_equal(String(hits.column_at(2).as_string().get(0)), "Fox and fox cubs")

# This split has no per-document length field, so scores use b = 0.
var idf = bm25_idf(2, 3)
var top = Float64(hits.column_at(0).as_primitive[DType.float64]().get(0))
assert_almost_equal(top, bm25_score_contribution(idf, 2, Bm25Params(b=0.0)))
```
