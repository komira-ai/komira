# =============================================================================
# komira_plan_conformance/cases_scan_avro.mojo -- shard scan_avro.
# =============================================================================
#
# Plans that scan Apache Avro's four upstream interop files (inputs/avro/,
# staged from //third_party/apache-avro) through komira_scan_source's
# AvroSource, which the plan carries as a binding of kind `komira.avro`.
# The shard tests the SCAN NODE at plan level: the scan's output schema, a
# projection (a subset, reordered), a filter above the scan and one pushed
# into the scan node onto a column the projection drops, and the same plan
# over each block codec. It does not test the encoding: reading these files
# value by value is komira_formats_e2e's test_formats_foreign_avro, at
# reader level.
#
# The oracle is upstream's, not komira's: share/test/data/weather.json at the
# pinned commit lists the five records every .avro file holds, and upstream's
# own C++ test (lang/c++/test/DataFileTests.cc, testCompatibility) reads all
# four files and checks those records. Every expected row below is a row of
# weather.json (re-derived twice, by hand); each derivation says so.
#
#   station         time            temp
#   011990-99999    -619524000000   0
#   011990-99999    -619506000000   22
#   011990-99999    -619484400000   -11
#   012650-99999    -655531200000   111
#   012650-99999    -655509600000   78
#
# Types: the writer schema in every file's header, and upstream's
# share/test/schemas/weather.avsc, is test.Weather {station: string, time:
# long, temp: int}, no field a union, so no column can hold NULL. The scan
# declares that schema (datasets.weather_schema: string, int64, int32, none
# nullable), and test_corpus checks it against weather.json's members and
# kinds (dataset `weather`). The query-semantics document has no item that
# maps a file format's types to plan types; §7.13 says Avro carries NULL
# explicitly and never converts.
#
# No root sorts, so every case compares its rows as a multiset (§4.8). The
# filter literal is INT32, the column's type, so no mixed comparison
# (§8.9, undecided) arises.
#
# Not here, and why:
#   - NULL flow through an Avro scan: test.Weather has no union field, so
#     no upstream file holds a NULL; a nullable Avro input needs a writer
#     independent of komira (fastavro, say).
#   - A declared schema that differs from the file's (a projection of a
#     column the file lacks, int for long): the document says nothing about
#     reader schema resolution, and the IR takes the declared schema on
#     trust; a refusal case waits for an executor.
#   - Avro logical types, enums, maps, arrays: nested types are out of the
#     document's scope, and the weather files hold none.
#
# The defect each case would catch once it executes:
#   full_scan                 a record dropped or repeated at a block edge;
#                             a scan whose output schema differs from the
#                             declared one (int32 widened to int64)
#   codec_deflate             a codec-specific decode path diverging from the
#   codec_snappy              null-codec one (the same five rows are
#   codec_zstandard           expected from every file)
#   projection_subset         a projection read by position rather than name
#                             (temp and station swapped), or ignored (time
#                             kept)
#   filter_temp_positive      a filter keeping temp = 0 (>= for >) or
#                             dropping a positive row
#   pushed_filter_drops_temp
#                             a pushed filter ignored because the kind
#                             cannot prune (komira.avro's gate rejects every
#                             predicate), or applied after the projection
#                             has dropped temp
# =============================================================================

from komira_plan_expr.expr import BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.avro_source import AvroSource
from komira_scan_source.source_variant import SourceVariant

from .plan_case import Case
from .datasets import avro_input, weather_schema

comptime SHARD = "scan_avro"


def _scan(
    codec: String,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    """A scan node over the weather file of `codec`, declaring test.Weather's
    schema, with an optional projection and pushed-down filter."""
    var src = AvroSource(avro_input(codec), weather_schema())
    return LogicalPlan.scan_from_source(
        SourceVariant(src^), weather_schema(), projection^, filter^
    )


def _temp_gt_0() -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref("temp"),
        Expr.literal(ScalarValue.from_int32(Int32(0))),
    )


def _full_scan() raises -> LogicalPlan:
    return _scan("null")


def _codec_deflate() raises -> LogicalPlan:
    return _scan("deflate")


def _codec_snappy() raises -> LogicalPlan:
    return _scan("snappy")


def _codec_zstandard() raises -> LogicalPlan:
    return _scan("zstandard")


def _projection_subset() raises -> LogicalPlan:
    var proj: List[String] = [String("temp"), String("station")]
    return _scan("null", Optional(proj^))


def _filter_temp_positive() raises -> LogicalPlan:
    return LogicalPlan.filter(_temp_gt_0(), _scan("null"))


def _pushed_filter_drops_temp() raises -> LogicalPlan:
    var proj: List[String] = [String("station"), String("time")]
    return _scan("null", Optional(proj^), Optional(_temp_gt_0()))


def cases() -> List[Case]:
    """The shard's cases. Without an ORDER BY a result's row order is not
    defined (§4.8), so every case compares its rows as a multiset."""
    return [
        Case.hand("full_scan", SHARD, _full_scan, CanonPolicy.unordered()),
        Case.hand("codec_deflate", SHARD, _codec_deflate, CanonPolicy.unordered()),
        Case.hand("codec_snappy", SHARD, _codec_snappy, CanonPolicy.unordered()),
        Case.hand("codec_zstandard", SHARD, _codec_zstandard, CanonPolicy.unordered()),
        Case.hand("projection_subset", SHARD, _projection_subset, CanonPolicy.unordered()),
        Case.hand("filter_temp_positive", SHARD, _filter_temp_positive, CanonPolicy.unordered()),
        Case.hand(
            "pushed_filter_drops_temp", SHARD, _pushed_filter_drops_temp,
            CanonPolicy.unordered(),
        ),
    ]
