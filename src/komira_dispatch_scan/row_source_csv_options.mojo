# =============================================================================
# row_source_csv_options.mojo — the CSV dialect scan-leaf accessor
# =============================================================================
#
# ONE FUNCTION: `_row_source_csv_options_for_dispatch`, which walks a plan to its
# SCAN leaf and returns the CSV dialect the plan DECLARES as a `CsvReadOptions`.
# Its production caller is the engine's parallel CSV decode of a scan leaf, on
# the columnar demote path.
#
# It lives in its own module, not beside its two sibling walkers in
# `row_column_reroute.mojo`, because it is the only one of the three that names
# `komira_csv`; the other two read only the plan IR.
#
# ⚠ THE DEFAULTS ARE `CSV_DEFAULT_*`, NEVER `get_i64`'s OWN `Int64(0)` — the
# docstring below carries the argument.

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
)
from komira_scan_source.source_variant import SOURCE_VARIANT_CSV
# `CSV_DEFAULT_*` are the `get_i64` DEFAULTS — never `get_i64`'s own `Int64(0)`,
# which would mean a NUL delimiter and `has_header=False` on a leaf carrying no
# params (a plan encoded by an older peer).
from komira_scan_source.csv_source import (
    CSV_DEFAULT_DELIMITER,
    CSV_DEFAULT_HAS_HEADER,
)
from komira_csv.csv_options import (
    CsvReadOptions,
    QUOTE_STYLE_TAG_RFC4180,
)


def _row_source_csv_options_for_dispatch(
    imm plan: LogicalPlan,
) raises -> CsvReadOptions:
    """Walk the plan to its SCAN leaf and return the CSV dialect the plan
    DECLARES, as a `CsvReadOptions` the row reader can be handed.

    ★ THIS FUNCTION CLOSES THE `separator` / `has_header` BIND-vs-EXECUTE
    SPLIT. Without it the reader would be handed a fresh DEFAULT
    `CsvReadOptions()`, so a non-comma delimiter (or `has_header=False`) would
    be honoured at INFERENCE and then re-derived from the file with COMMA /
    header-on at EXECUTION; the two answers disagree and the read raises
    `scan input column 'id' not found in the CSV header`. Nothing is lost on
    the wire — the CSV binding writes `delimiter` / `has_header` /
    `quote_style_tag` as `ScanParams` and the wire codec round-trips the whole
    map — the dialect simply has to be ASKED for at the dispatch site.

    ⚠ THE `get_i64` DEFAULTS ARE `CSV_DEFAULT_*`, NOT `get_i64`'s OWN `0`.
    A missing `delimiter` param must mean a COMMA, not a NUL byte, and a
    missing `has_header` must mean TRUE, not False.

    On a same-version plan this fallback is unreachable BY CONSTRUCTION:
    `SOURCE_VARIANT_CSV` has two constructors — `SourceVariant(CsvSource)`,
    which `put_i64`s `delimiter` + `has_header` unconditionally, and the
    kw-only `SourceVariant(tag=, binding=)`, which the wire decoder uses with a
    verbatim copy of the ENCODER's params. Encode and decode therefore
    preserve both keys.

    THE DOOR THAT IS NOT CLOSED — and why this is a default and NOT an assert:
    the encoder on the other side of the wire need not be this build. A plan
    from an older peer whose CSV binding wrote only `path` + `quote_style_tag`
    arrives here missing both keys. For that plan a comma and a header is the
    correct reading; `Int64(0)` is a NUL delimiter and a silently different
    row count. Raising instead would turn a decodable cross-version plan into a
    crash. The test that reaches this branch builds the leaf through the same
    kw-only constructor the wire decoder uses.

    ⚠ THE TRANSITIONAL CSV LEAF THAT RIDES THE PARQUET ARM HAS NO CSV
    BINDING. The legacy `LogicalPlan.scan(path, SOURCE_CSV, ...)` factory
    rides the
    `SOURCE_VARIANT_PARQUET` arm with `source_kind == ROW` — see
    `_row_source_path_for_dispatch`. Reading a CSV dialect off it is not
    possible and not wanted: it takes the defaults.
    """
    var tag = plan.tag
    if tag == PLAN_SCAN:
        if not plan._scan:
            raise Error(
                "row scan walk: PLAN_SCAN missing ScanData (IR"
                " invariant violated)."
            )
        var o = CsvReadOptions()
        o.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
        ref scan_data = plan.scan_data_ref()
        ref src = scan_data.source
        if src.tag == SOURCE_VARIANT_CSV:
            ref params = src.binding_ref().params
            o.delimiter = UInt8(
                Int(
                    params.get_i64(
                        String("delimiter"), Int64(Int(CSV_DEFAULT_DELIMITER))
                    )
                )
            )
            o.has_header = params.get_i64(
                String("has_header"),
                Int64(1) if CSV_DEFAULT_HAS_HEADER else Int64(0),
            ) != Int64(0)
            # Threaded for the same reason as the other two: `_csv_binding`
            # puts it on the leaf, and the reader dispatches its comptime
            # scanner off it. Inert today (every producer emits 0 = RFC4180),
            # and the point of doing it here is that it cannot go stale.
            o.quote_style_tag = Int(
                params.get_i64(
                    String("quote_style_tag"), Int64(QUOTE_STYLE_TAG_RFC4180)
                )
            )
        return o^
    # Single-child descent — the SAME linear in-scope chain shapes the path and
    # variant walkers in `row_column_reroute` descend. Three walkers rather
    # than one multi-return walker because each is independently callable and the shapes
    # must not drift; if a new chain node is added, all three need the arm.
    if tag == PLAN_FILTER and plan._filter:
        return _row_source_csv_options_for_dispatch(
            plan.filter_data_ref().child[]
        )
    if tag == PLAN_PROJECT and plan._project:
        return _row_source_csv_options_for_dispatch(
            plan.project_data_ref().child[]
        )
    if tag == PLAN_LIMIT and plan._limit:
        return _row_source_csv_options_for_dispatch(
            plan.limit_data_ref().child[]
        )
    if tag == PLAN_SORT and plan._sort:
        return _row_source_csv_options_for_dispatch(
            plan.sort_data_ref().child[]
        )
    if tag == PLAN_DISTINCT and plan._distinct:
        return _row_source_csv_options_for_dispatch(
            plan.distinct_data_ref().child[]
        )
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return _row_source_csv_options_for_dispatch(
            plan.aggregate_data_ref().child[]
        )
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _row_source_csv_options_for_dispatch(
            plan.partition_by_data_ref().child[]
        )
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return _row_source_csv_options_for_dispatch(
            plan.partition_topn_data_ref().child[]
        )
    if tag == PLAN_TOPN and plan._topn:
        return _row_source_csv_options_for_dispatch(
            plan.topn_data_ref().child[]
        )
    raise Error(
        "row scan walk: plan tag "
        + String(Int(tag))
        + " is not a row-streaming single-child chain node — cannot reach the"
        " scan leaf to recover the CSV dialect."
    )
