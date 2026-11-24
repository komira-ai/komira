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
- `parquet_schema_bytes`: a Parquet file's schema as `komira.plan.v1`
  `WireSchema` bytes.
- `csv_binding_bytes`, `json_binding_bytes`: the whole `WireScanBinding` of a
  CSV or newline-delimited JSON file, schema inferred from a bounded prefix.
- `plan_render_text`: a serialized plan decoded and printed, not run.
- `sql_result`: one SQL statement run on a session's engine, its answer as
  batches checked to cross the Arrow C Stream Interface. A refusal is
  recorded on the session as its last error, with the step and the code.
"""

from byte_buffer.file_identity import FileIdentity
from csv.csv_options import QUOTE_STYLE_TAG_RFC4180
from plan_wire import binding_to_bytes, plan_from_bytes, schema_to_bytes
from scan_source.csv_source import CsvSource
from scan_source.json_source import JsonSource
from scan_source.source_variant import SourceVariant
from sdk.parquet_footer import read_parquet_footer
from sdk_exec.arrow_result import ArrowResult, arrow_result
from sdk_exec.engine_catalog import register_parquet as engine_register_parquet
from sdk_exec.engine_sql import run_sql
from sql.sql_ast import TvfOptions
from sql.sql_tvf_bind import csv_tvf_schema, json_tvf_schema

from .session import Session


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
        has no column. Nothing is registered then.
    """
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
        that is missing, unreadable or holds no object. Nothing is registered
        then.
    """
    _check_name_free(session, name)
    session.engine.catalog.add_source(name, _json_source(path))


def _check_name_free(session: Session, name: String) raises:
    """Refuse a name a new table cannot take: an empty one, or one the
    session's catalog already holds. The catalog resolves a name to its first
    registration, so a second table under a taken name would never be read;
    it is refused here instead of being shadowed."""
    if name.byte_length() == 0:
        raise Error("TABLE_NAME_EMPTY: a table name must not be empty")
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
    # The binding is taken from the source variant, which owns the parameter
    # set that is the scan's identity.
    var variant = _csv_source(path, delimiter, has_header, all_varchar)
    return binding_to_bytes(variant.binding_ref(), variant.tag)


def json_binding_bytes(path: String) raises -> List[UInt8]:
    """The `WireScanBinding` of the newline-delimited JSON file at `path`.

    The schema is inferred from the leading records (a bounded prefix, cut at
    the last complete line).
    """
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
    (`register_parquet`, `register_csv`, `register_json`); it is `sdk_exec.run_sql`: a query, or a
    `COPY ... TO` a local file, whose answer is one row of the BIGINT
    `Count`. An answer of no rows is one batch of no rows with the answer's
    schema. The result owns its batches and keeps no reference to the
    session, which may be dropped first.

    Raises:
        Error `<step>: <reason>` when `run_sql` refuses (the session records
        it too, with its step and code: `Session.set_refusal`), where `<step>` is the
        step that refused (`parse`, `bind`, `optimize`, `lower` or
        `execute`) and `<reason>` its own message, unchanged; and the export
        check's error naming the column when a result column cannot cross the
        stream (`arrow_result`).
    """
    var outcome = run_sql(session.engine, sql)
    if outcome.refusal:
        ref refusal = outcome.refusal.value()
        session.set_refusal(refusal.step, refusal.reason.copy())
        raise Error(session.last_error())
    return arrow_result(outcome^)
