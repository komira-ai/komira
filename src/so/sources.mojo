"""The source and render operations behind the C surface, as safe Mojo.

Each function here is what one `komira_*` export does once its pointers have
been turned into values: it takes a path, a name or the bytes of a plan, and
returns bytes or text, or raises with the engine's own message. `_c_abi.mojo`
turns a raise into `KOMIRA_ERR_ENGINE` and the message into the context's last
error. Nothing here holds a pointer.

- `register_parquet`: bind Parquet files (one file, a glob or a directory)
  into a session's engine under a name, after reading their footers.
- `parquet_schema_bytes`: a Parquet file's schema as `komira.plan.v1`
  `WireSchema` bytes.
- `csv_binding_bytes`, `json_binding_bytes`: the whole `WireScanBinding` of a
  CSV or newline-delimited JSON file, schema inferred from a bounded prefix.
- `plan_render_text`: a serialized plan decoded and printed, not run.
- `sql_result`: one SQL statement run on a session's engine, its answer as
  batches checked to cross the Arrow C Stream Interface; in its second form,
  under a caller's `RunControl`, whose cancel refuses the run with the named
  error `QUERY_CANCELLED` (`is_cancelled_error`).
"""

from byte_buffer.file_identity import FileIdentity
from plan_wire import binding_to_bytes, plan_from_bytes, schema_to_bytes
from scan_source.csv_source import CsvSource
from scan_source.json_source import JsonSource
from scan_source.source_variant import SourceVariant
from sdk.parquet_footer import read_parquet_footer
from sdk_exec.arrow_result import ArrowResult, arrow_result
from sdk_exec.engine_catalog import register_parquet as engine_register_parquet
from sdk_exec.engine_sql import STEP_EXECUTE, run_sql
from sdk_exec.run_control import RunControl
from sql.sql_ast import TvfOptions
from sql.sql_tvf_bind import csv_tvf_schema, json_tvf_schema

from .session import Session

comptime QUERY_CANCELLED = "QUERY_CANCELLED"
"""The named error of a run its `RunControl` cancelled: `sql_result` raises
`QUERY_CANCELLED: execute: <the engine's cancelled error>`."""


def register_parquet(mut session: Session, name: String, path: String) raises:
    """Bind the Parquet files at `path` into `session`'s engine under `name`.

    `path` is what `sdk_exec.engine_catalog.register_parquet` takes: one file,
    a glob or a directory. The footers are read here, through the engine's own
    footer reader, so a missing or unreadable file is refused at registration
    with the reader's own message and not later as an empty result, and the
    table is in the catalog a query on the session binds against. A flat
    schema only: a nested or repeated column is refused, as are files whose
    schemas differ and a glob that matches nothing.
    """
    engine_register_parquet(session.engine, name, path)


def parquet_schema_bytes(path: String) raises -> List[UInt8]:
    """The Arrow schema of the Parquet file at `path`, as `WireSchema` bytes.

    Read from the footer alone; no data page is touched.
    """
    var footer = read_parquet_footer(path)
    var schema = footer.take_schema()
    return schema_to_bytes(schema)


def csv_binding_bytes(
    path: String, delimiter: UInt8, has_header: Bool, all_varchar: Bool
) raises -> List[UInt8]:
    """The `WireScanBinding` of the CSV file at `path`, as bytes.

    The schema is inferred from a bounded prefix of an uncompressed file (a
    compressed file is read whole). `delimiter`, `has_header` and
    `all_varchar` change what the cells mean, so they are inputs: the first
    two enter the binding's identity, and `all_varchar` makes every column a
    string.
    """
    var opts = TvfOptions()
    opts.delimiter = delimiter
    opts.has_header = has_header
    opts.all_varchar = all_varchar
    var schema = csv_tvf_schema(path, opts)
    var source = CsvSource(
        String(path),
        schema^,
        mtime_ns=UInt64(FileIdentity.stat_path(path).mtime_ns),
        quote_style_tag=0,
        delimiter=delimiter,
        has_header=has_header,
    )
    # The binding is taken from the source variant, which owns the parameter
    # set that is the scan's identity.
    var variant = SourceVariant(source^)
    return binding_to_bytes(variant.binding_ref(), variant.tag)


def json_binding_bytes(path: String) raises -> List[UInt8]:
    """The `WireScanBinding` of the newline-delimited JSON file at `path`.

    The schema is inferred from the leading records (a bounded prefix, cut at
    the last complete line).
    """
    var schema = json_tvf_schema(path)
    var source = JsonSource(
        String(path),
        schema^,
        mtime_ns=UInt64(FileIdentity.stat_path(path).mtime_ns),
    )
    var variant = SourceVariant(source^)
    return binding_to_bytes(variant.binding_ref(), variant.tag)


def plan_render_text(var plan_bytes: List[UInt8]) raises -> String:
    """Decode a serialized plan (a `WirePlanEnvelope`) and print it.

    The text is the plan as authored, before any optimizer rule: the same
    text its structural hash is computed over. The plan is not run. Decoding
    applies the wire's admission checks, so a malformed or hostile plan
    raises and is not rendered.
    """
    var plan = plan_from_bytes(plan_bytes^)
    return String(plan)


def sql_result(mut session: Session, sql: String) raises -> ArrowResult:
    """Run the SQL statement `sql` on `session`'s engine and return its answer,
    every batch checked to cross the Arrow C Stream Interface whole.

    The statement reads the tables registered on the session
    (`register_parquet`); it is `sdk_exec.run_sql`: a query, or a
    `COPY ... TO` a local file, whose answer is one row of the BIGINT
    `Count`. An answer of no rows is one batch of no rows with the answer's
    schema. The result owns its batches and keeps no reference to the
    session, which may be dropped first.

    Raises:
        Error `<step>: <reason>` when `run_sql` refuses, where `<step>` is the
        step that refused (`parse`, `bind`, `optimize`, `lower` or
        `execute`) and `<reason>` its own message, unchanged; and the export
        check's error naming the column when a result column cannot cross the
        stream (`arrow_result`).
    """
    return sql_result(session, sql, RunControl())


def sql_result(
    mut session: Session, sql: String, control: RunControl
) raises -> ArrowResult:
    """`sql_result` under `control`: the run polls the control's cancel token
    and counts its segments into the control's progress.

    Raises:
        Error `QUERY_CANCELLED: execute: <reason>` when the run is refused at
        step `execute` and the control is cancelled (the cancel stopped the
        run, or came while it failed for a reason of its own); a cancel that
        comes after the run's last check leaves the answer standing. A
        statement refused before its plan runs raises `<step>: <reason>` as
        without a control, and so does every other refusal.
    """
    var outcome = run_sql(session.engine, sql, control)
    if outcome.refusal:
        ref refusal = outcome.refusal.value()
        var text = refusal.step + ": " + refusal.reason
        if refusal.step == String(STEP_EXECUTE) and control.is_cancelled():
            raise Error(String(QUERY_CANCELLED) + ": " + text)
        raise Error(text)
    return arrow_result(outcome^)


def is_cancelled_error(text: String) -> Bool:
    """Whether `text` is the error `sql_result` raises for a cancelled run:
    it starts with `QUERY_CANCELLED: `. No other error of `sql_result` does,
    since those start with a step name or the export check's own words."""
    return text.startswith(String(QUERY_CANCELLED) + ": ")
