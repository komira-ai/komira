"""The source and render operations behind the C surface, as safe Mojo.

Each function here is what one `komira_*` export does once its pointers have
been turned into values: it takes a path, a name or the bytes of a plan, and
returns bytes or text, or raises with the engine's own message. `_c_abi.mojo`
turns a raise into `KOMIRA_ERR_ENGINE` and the message into the context's last
error. Nothing here holds a pointer.

- `register_parquet`: bind Parquet files (one file, a glob or a directory)
  into a session's engine under a name, after reading their footers.
- `register_csv`, `register_json`: bind one CSV or newline-delimited JSON
  file into a session's engine under a name, schema inferred now, as
  `read_csv` and `read_json` bind it.
- `register_arrow`: bind a table already in memory (what
  `komira_register_arrow_stream` drained from an Arrow C stream) into a
  session's engine under a name, replacing a table of that name;
  `check_table_name` is its name check, which the C call makes before it
  drains the stream.
- `parquet_schema_bytes`: a Parquet file's schema as `komira.plan.v1`
  `WireSchema` bytes.
- `parquet_source_bytes`: the Parquet files a path names (one file, a glob or
  a directory), resolved as `register_parquet` resolves them, as
  `WireParquetSource` bytes: the sorted files, their schema and the Hive
  partition columns a `KOMIRA_HIVE_*` mode asks for.
- `csv_binding_bytes`, `json_binding_bytes`: the whole `WireScanBinding` of a
  CSV or newline-delimited JSON file, schema inferred from a bounded prefix.
- `plan_render_text`: a serialized plan decoded and printed, not run.
- `sql_result`: one SQL statement run on a session's engine, its answer as
  batches checked to cross the Arrow C Stream Interface; in its second form,
  under a caller's `RunControl`, whose cancel refuses the run with the named
  error `QUERY_CANCELLED` (`is_cancelled_error`). A refusal is
  recorded on the session as its last error, with the step and the code.
- `plan_result`: a serialized plan (a `WirePlanEnvelope`) decoded and run on
  a session's engine, with no SQL text anywhere on the way, its answer as
  `sql_result`'s is; an envelope that carries a write target writes its
  answer to that file and answers the rows written.

Every operation but `plan_render_text` and `register_arrow` (which read no
file) first calls `probe_codec_libraries` (libzstd, libz, liblz4), so a codec
library missing from the host is a raise
`compression: cannot load <soname>: <loader error>` before anything is read,
and not an abort of the process when a codec first opens it.
"""

from arrow.arrow_types import ArrowType
from aws_core import AwsClock
from arrow.table import Table
from arrow.write_target import WriteTarget
from byte_buffer.file_identity import FileIdentity
from compression.codec_libraries import probe_codec_libraries
from csv.csv_options import QUOTE_STYLE_TAG_RFC4180
from http_core.transport.io_stream import Connector
from parquet_footers.parquet_files import resolve_parquet_source
from plan_ir.logical_plan import LogicalPlan
from plan_wire import (
    PLAN_WIRE_UDFS_DROPPED,
    binding_to_bytes,
    parquet_source_to_bytes,
    plan_envelope_from_bytes,
    plan_from_bytes,
    schema_to_bytes,
)
from scan_source.csv_source import CsvSource
from scan_source.json_source import JsonSource
from scan_source.source_variant import SourceVariant
from sdk.parquet_footer import read_parquet_footer
from sdk_exec.arrow_result import ArrowResult, arrow_result
from sdk_exec.engine_plan import SqlOutcome, run_plan, run_plan_write
from sdk_exec.engine_context import RegisteredTable
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, run_sql_with
from sdk_exec.run_control import RunControl
from sql.sql_ast import (
    HIVE_PARTITIONING_AUTO,
    HIVE_PARTITIONING_OFF,
    HIVE_PARTITIONING_ON,
    TvfOptions,
)
from sql.sql_tvf_bind import csv_tvf_schema, json_tvf_schema

from .bindings import forget_table, store_opener
from .session import Session, step_number
from .status import KOMIRA_HIVE_AUTO, KOMIRA_HIVE_OFF, KOMIRA_HIVE_ON
from .store_fs import StoreConnectors, StoreScanFs, kernel_store_connectors

comptime TABLE_TYPE_UNSUPPORTED = "TABLE_TYPE_UNSUPPORTED"
"""Refusal of `register_arrow`: a column of a nested type (list, large list,
fixed-size list, struct, map) or a union. Only flat columns are registered,
as only flat Parquet files are (`register_parquet`)."""

comptime QUERY_CANCELLED = "QUERY_CANCELLED"
"""The named error of a run its `RunControl` cancelled: `sql_result` raises
`QUERY_CANCELLED: execute: <the engine's cancelled error>`."""

comptime HIVE_PARTITIONING_UNKNOWN = "HIVE_PARTITIONING_UNKNOWN"
"""Refusal of `parquet_source_bytes`: a Hive mode that is none of
`KOMIRA_HIVE_AUTO`, `KOMIRA_HIVE_ON` and `KOMIRA_HIVE_OFF`."""

comptime STEP_DECODE = "decode"
"""The step of `plan_result` that turns the plan's bytes into a plan; the
steps after it are `run_plan`'s (`optimize`, `lower`, `execute`)."""


def register_parquet(mut session: Session, name: String, path: String) raises:
    """Bind the Parquet files at `path` into `session`'s engine under `name`.

    `path` is what `sdk_exec.engine_catalog.register_parquet` takes: one file,
    a glob or a directory. The footers are read here, through the engine's own
    footer reader, so a missing or unreadable file is refused at registration
    with the reader's own message and not later as an empty result, and the
    table is in the catalog a query on the session binds against. A flat
    schema only: a nested or repeated column is refused, as are files whose
    schemas differ and a glob that matches nothing. A table already under
    `name` (any kind, any case) is replaced, as `add_sql_binding` replaces
    it; a refused registration leaves it as it was.

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before anything is read.
    """
    probe_codec_libraries()
    var source = resolve_parquet_source(
        session.engine.footers, path, HIVE_PARTITIONING_AUTO, True
    )
    forget_table(session, name)
    session.engine.catalog.add_parquet_source(name, source^)
    session.engine.tables.append(RegisteredTable(name.lower(), path))


def register_csv(
    mut session: Session,
    name: String,
    path: String,
    delimiter: UInt8,
    has_header: Bool,
    all_varchar: Bool,
) raises:
    """Bind the CSV file at `path` into `session`'s engine as the table `name`.

    The table is the scan `read_csv` builds for the same file and dialect
    (`csv_binding_bytes` holds the same source): the schema is inferred now
    from a bounded prefix of an uncompressed file (a compressed one is read
    whole), `delimiter` and `has_header` are the dialect the file is read
    with, and `all_varchar` makes every column a string. A query on the
    session then reads it by name, found without regard to case. The schema
    is the one inferred here: the file is read at it by every later query.
    A query on a table registered with `has_header` False is refused at
    `lower`, naming `header=false`, as one on `read_csv(..., header=false)` is.

    Raises:
        `TABLE_NAME_EMPTY` for an empty `name`; `TABLE_ALREADY_REGISTERED`
        when the session already holds a table of that name (of any kind);
        the inference's own error for a file that is missing, unreadable or
        has no column; `compression: cannot load <soname>: <loader error>`
        when a codec library cannot be loaded. Nothing is registered then.
    """
    probe_codec_libraries()
    _check_name_free(session, name)
    session.engine.catalog.add_source(
        name, _csv_source(path, delimiter, has_header, all_varchar)
    )


def register_json(mut session: Session, name: String, path: String) raises:
    """Bind the newline-delimited JSON file at `path` into `session`'s engine
    as the table `name`.

    The table is the scan `read_json` builds for the same file
    (`json_binding_bytes` holds the same source): the schema is inferred now
    from the leading records. A query on the session then reads it by name,
    found without regard to case.

    Raises:
        As `register_csv`, with the JSON inference's own error for a file
        that is missing, unreadable or holds no object, and `compression:
        cannot load <soname>: <loader error>` when a codec library cannot be
        loaded. Nothing is registered then.
    """
    probe_codec_libraries()
    _check_name_free(session, name)
    session.engine.catalog.add_source(name, _json_source(path))


def register_arrow(mut session: Session, name: String, var table: Table) raises:
    """Bind `table`, rows already in memory, into `session`'s engine as the
    table `name`, replacing the table the session holds under that name, of
    any kind, as DuckDB's `register` replaces a view of the name.

    The table is resident: its chunks are moved into the catalog and every
    query reads them, so later changes to whatever the rows were copied from
    are not seen. A query on the session reads it by name, found without
    regard to case. A table of no chunk is a table of no row with its schema.

    Raises:
        `TABLE_NAME_EMPTY` for an empty `name` (`check_table_name`);
        `TABLE_TYPE_UNSUPPORTED` naming the first column whose type is nested
        or a union. Nothing is registered or replaced then.
    """
    check_table_name(name)
    for i in range(table.num_columns()):
        var t = table.schema().field_arrow_type(i)
        if (
            t.is_nested()
            or t == ArrowType.UNION_SPARSE
            or t == ArrowType.UNION_DENSE
        ):
            raise Error(
                String(TABLE_TYPE_UNSUPPORTED)
                + ": column '"
                + table.schema().field_name(i)
                + "' has type "
                + String(t)
                + "; only flat columns are registered"
            )
    # A Parquet table is also listed with its paths (`EngineContext.tables`),
    # which lowering reads for every Parquet scan, and a table bound to an
    # object store with its bucket; a replaced one leaves both.
    forget_table(session, name)
    session.engine.catalog.add_in_memory(name, table^)


def check_table_name(name: String) raises:
    """Refuse a name no table can take: an empty one (`TABLE_NAME_EMPTY`).
    It is the name check of `register_arrow`, which replaces a taken name
    instead of refusing it."""
    if name.byte_length() == 0:
        raise Error("TABLE_NAME_EMPTY: a table name must not be empty")


def _check_name_free(session: Session, name: String) raises:
    """Refuse a name a new table cannot take: an empty one, or one the
    session's catalog already holds. The catalog resolves a name to its first
    registration, so a second table under a taken name would never be read;
    it is refused here instead of being shadowed."""
    check_table_name(name)
    if session.engine.catalog.has(name):
        raise Error(
            "TABLE_ALREADY_REGISTERED: the session already has a table named '"
            + name
            + "'"
        )


def _csv_source(
    path: String, delimiter: UInt8, has_header: Bool, all_varchar: Bool
) raises -> SourceVariant:
    """The source of a CSV file, as `read_csv` binds it: the inferred schema
    (every column a string with `all_varchar`), the file's mtime as its
    snapshot, and the dialect it is read with."""
    var opts = TvfOptions()
    opts.delimiter = delimiter
    opts.has_header = has_header
    opts.all_varchar = all_varchar
    var schema = csv_tvf_schema(path, opts)
    var source = CsvSource(
        String(path),
        schema^,
        mtime_ns=UInt64(FileIdentity.stat_path(path).mtime_ns),
        quote_style_tag=QUOTE_STYLE_TAG_RFC4180,
        delimiter=delimiter,
        has_header=has_header,
    )
    return SourceVariant(source^)


def _json_source(path: String) raises -> SourceVariant:
    """The source of a newline-delimited JSON file, as `read_json` binds it:
    the schema inferred from the leading records and the file's mtime as its
    snapshot."""
    var schema = json_tvf_schema(path)
    var source = JsonSource(
        String(path),
        schema^,
        mtime_ns=UInt64(FileIdentity.stat_path(path).mtime_ns),
    )
    return SourceVariant(source^)


def parquet_schema_bytes(path: String) raises -> List[UInt8]:
    """The Arrow schema of the Parquet file at `path`, as `WireSchema` bytes.

    Read from the footer alone; no data page is touched.

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before anything is read.
    """
    probe_codec_libraries()
    var footer = read_parquet_footer(path)
    var schema = footer.take_schema()
    return schema_to_bytes(schema)


def parquet_source_bytes(
    session: Session, path: String, hive_partitioning: Int32
) raises -> List[UInt8]:
    """The Parquet files at `path` as `WireParquetSource` bytes.

    `path` is what `register_parquet` takes: one file, a glob (every file it
    matches, sorted byte-wise) or a directory (every `.parquet` file under
    it). The files and their footers are read now, through the session's
    footer reader, and every file must have the first file's schema. The
    source's schema is the files' columns; the Hive partition columns, which
    a scan reads after them, are those `hive_partitioning` asks for:
    `KOMIRA_HIVE_AUTO` when every file has the same keys,
    `KOMIRA_HIVE_ON` refusing files whose keys differ, `KOMIRA_HIVE_OFF`
    none.

    Raises:
        `HIVE_PARTITIONING_UNKNOWN` for any other mode, before anything is
        read; the errors of `resolve_parquet_source` (among them
        `PARQUET_GLOB_NO_MATCH`, naming the pattern, and
        `PARQUET_FILES_SCHEMA_MISMATCH`); an error naming a file whose footer
        does not read; `compression: cannot load <soname>: <loader error>`
        when a codec library cannot be loaded, before anything is read.
    """
    var mode: UInt8
    if hive_partitioning == KOMIRA_HIVE_AUTO:
        mode = HIVE_PARTITIONING_AUTO
    elif hive_partitioning == KOMIRA_HIVE_ON:
        mode = HIVE_PARTITIONING_ON
    elif hive_partitioning == KOMIRA_HIVE_OFF:
        mode = HIVE_PARTITIONING_OFF
    else:
        raise Error(
            HIVE_PARTITIONING_UNKNOWN
            + ": hive_partitioning "
            + String(hive_partitioning)
            + " is none of KOMIRA_HIVE_AUTO (0), KOMIRA_HIVE_ON (1) and"
            + " KOMIRA_HIVE_OFF (2)"
        )
    probe_codec_libraries()
    var source = resolve_parquet_source(session.engine.footers, path, mode, True)
    return parquet_source_to_bytes(source)


def csv_binding_bytes(
    path: String, delimiter: UInt8, has_header: Bool, all_varchar: Bool
) raises -> List[UInt8]:
    """The `WireScanBinding` of the CSV file at `path`, as bytes.

    The schema is inferred from a bounded prefix of an uncompressed file (a
    compressed file is read whole). `delimiter`, `has_header` and
    `all_varchar` change what the cells mean, so they are inputs: the first
    two enter the binding's identity, and `all_varchar` makes every column a
    string.

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before anything is read.
    """
    probe_codec_libraries()
    # The binding is taken from the source variant, which owns the parameter
    # set that is the scan's identity.
    var variant = _csv_source(path, delimiter, has_header, all_varchar)
    return binding_to_bytes(variant.binding_ref(), variant.tag)


def json_binding_bytes(path: String) raises -> List[UInt8]:
    """The `WireScanBinding` of the newline-delimited JSON file at `path`.

    The schema is inferred from the leading records (a bounded prefix, cut at
    the last complete line).

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before anything is read.
    """
    probe_codec_libraries()
    var variant = _json_source(path)
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
    (`register_parquet`, `register_csv`, `register_json`,
    `register_arrow`, `add_sql_binding`); it is `sdk_exec.run_sql_with` over
    the session's bound object stores (`bindings.store_opener`): a query, or a
    `COPY ... TO` a local file, whose answer is one row of the BIGINT
    `Count`. An answer of no rows is one batch of no rows with the answer's
    schema. The result owns its batches and keeps no reference to the
    session, which may be dropped first.

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before the statement is parsed.

        Error `<step>: <reason>` when the run refuses (the session records
        it too, with its step and code: `Session.set_refusal`), where `<step>` is the
        step that refused (`parse`, `bind`, `optimize`, `lower` or
        `execute`) and `<reason>` its own message, unchanged, followed by
        ` at line <L>, column <C>` (both from 1) for a refusal of the parse
        step, where the text stopped parsing; and the export
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
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before the statement is parsed.

        Error `QUERY_CANCELLED: execute: <reason>` when the run is refused at
        step `execute` and the control is cancelled (the cancel stopped the
        run, or came while it failed for a reason of its own); a cancel that
        comes after the run's last check leaves the answer standing. A
        statement refused before its plan runs raises `<step>: <reason>` as
        without a control, and so does every other refusal.
    """
    return sql_result_with(session, sql, control, kernel_store_connectors())


def sql_result_with[
    S3C: Connector, AZC: Connector, K: AwsClock & Copyable & Deinitable
](
    mut session: Session,
    sql: String,
    control: RunControl,
    var connectors: StoreConnectors[S3C, AZC, K],
) raises -> ArrowResult:
    """`sql_result` under `control`, reading the session's bound object stores
    through the connectors and clock `connectors` gives: the file systems of
    `store_opener`, built from the credentials sealed on the session now. A
    credential a bound table names that cannot be read refuses the statement
    at step `bind` (`<step>: <reason>`, recorded on the session).
    """
    probe_codec_libraries()
    var opener: StoreScanFs[S3C, AZC, K]
    try:
        opener = store_opener(session, connectors^)
    except e:
        session.set_refusal(String(STEP_BIND), String(e))
        raise Error(session.last_error())
    var outcome = run_sql_with(session.engine, sql, opener^, control)
    if outcome.refusal:
        ref refusal = outcome.refusal.value()
        if refusal.step == String(STEP_EXECUTE) and control.is_cancelled():
            # The cancel's name leads the text, so `error_code` reads it as
            # the code; the step stays `execute`.
            session.set_error(
                String(QUERY_CANCELLED) + ": " + refusal.step + ": " + refusal.reason,
                step_number(refusal.step),
            )
        else:
            var reason = refusal.reason.copy()
            if refusal.position:
                reason += " at " + String(refusal.position.value())
            session.set_refusal(refusal.step, reason^)
        raise Error(session.last_error())
    return arrow_result(outcome^)


def is_cancelled_error(text: String) -> Bool:
    """Whether `text` is the error `sql_result` raises for a cancelled run:
    it starts with `QUERY_CANCELLED: `. No other error of `sql_result` does,
    since those start with a step name or the export check's own words."""
    return text.startswith(String(QUERY_CANCELLED) + ": ")


def plan_result(mut session: Session, var plan_bytes: List[UInt8]) raises -> ArrowResult:
    """Decode the serialized plan `plan_bytes` (an authored `WirePlanEnvelope`)
    and run it on `session`'s engine, returning its answer as `sql_result`
    does: every batch checked to cross the Arrow C Stream Interface whole.

    The envelope is decoded with `plan_wire.plan_envelope_from_bytes` (the
    wire's admission, value and UDF checks) and then optimized, lowered and run
    in-process (`sdk_exec.engine_plan.run_plan`); it is never turned into SQL
    text, and the SQL front end does not run. A scan carries its own source, so
    the plan needs no table registered on the session. The result owns its
    batches and keeps no reference to the session.

    An envelope with a write target (`WirePlanEnvelope.write_target`) is run by
    `sdk_exec.engine_plan.run_plan_write` instead: the plan's rows are written
    to the destination as a local Parquet, CSV or newline-delimited JSON file,
    all or nothing, and the answer is one row, the NOT NULL BIGINT column
    `Count` holding the rows written. The destination is checked at `bind`
    before the plan runs, so a refused write touches no file.

    Raises:
        Error `compression: cannot load <soname>: <loader error>` when a codec
        library cannot be loaded, before the plan is decoded.

        Error `<step>: <reason>`, where `<step>` is `decode` when the bytes are
        not a plan this build runs (among them an envelope that carries UDFs,
        `PLAN_WIRE_UDFS_DROPPED`: the plan door runs no user function yet),
        `bind` when a write's destination or compression is refused
        (`STORAGE_URL_REFUSED`, `COPY_COMPRESSION_UNSUPPORTED`), and otherwise
        the step of `run_plan` that refused (`optimize`, `lower` or `execute`;
        a destination that cannot be written, `STORAGE_NOT_FOUND`, is refused
        at `execute`); `<reason>` is that step's own message, unchanged. The
        session records the refusal too (`Session.set_refusal`): its step is
        `step_number(<step>)`, which is `KOMIRA_STEP_NONE` for `decode`, and
        its code `error_code(<reason>)`. And the export check's error naming
        the column when a result column cannot cross the stream
        (`arrow_result`), which the session does not record.
    """
    probe_codec_libraries()
    var plan: LogicalPlan
    var target: Optional[WriteTarget]
    try:
        var decoded = plan_envelope_from_bytes(plan_bytes^)
        if len(decoded.udfs) > 0:
            raise Error(
                String(PLAN_WIRE_UDFS_DROPPED)
                + ": these bytes carry "
                + String(len(decoded.udfs))
                + " UdfRef entries (`WirePlanEnvelope.udfs`), and the plan"
                " door runs no user function yet"
            )
        target = decoded.write_target.copy()
        plan = decoded.take_plan()
    except e:
        # `decode` is no `KOMIRA_STEP_*` step: `step_number` gives it
        # `KOMIRA_STEP_NONE`, and the code is the decoder's.
        session.set_refusal(String(STEP_DECODE), String(e))
        raise Error(session.last_error())
    var outcome: SqlOutcome
    if target:
        outcome = run_plan_write(session.engine, plan^, target.value())
    else:
        outcome = run_plan(session.engine, plan^)
    if outcome.refusal:
        ref refusal = outcome.refusal.value()
        session.set_refusal(refusal.step, refusal.reason.copy())
        raise Error(session.last_error())
    return arrow_result(outcome^)
