"""The source and render operations behind the C surface, as safe Mojo.

Each function here is what one `komira_*` export does once its pointers have
been turned into values: it takes a path, a name or the bytes of a plan, and
returns bytes or text, or raises with the engine's own message. `_c_abi.mojo`
turns a raise into `KOMIRA_ERR_ENGINE` and the message into the context's last
error. Nothing here holds a pointer.

- `register_parquet`: bind a Parquet file into a session under a name, after
  reading its footer.
- `parquet_schema_bytes`: a Parquet file's schema as `komira.plan.v1`
  `WireSchema` bytes.
- `csv_binding_bytes`, `json_binding_bytes`: the whole `WireScanBinding` of a
  CSV or newline-delimited JSON file, schema inferred from a bounded prefix.
- `plan_render_text`: a serialized plan decoded and printed, not run.
"""

from komira_buffer.file_identity import FileIdentity
from komira_plan_wire import binding_to_bytes, plan_from_bytes, schema_to_bytes
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import SourceVariant
from komira_sdk.parquet_footer import read_parquet_footer
from komira_sql.sql_ast import TvfOptions
from komira_sql.sql_tvf_bind import csv_tvf_schema, json_tvf_schema

from .session import Session


def register_parquet(mut session: Session, name: String, path: String) raises:
    """Bind the Parquet file at `path` into `session` under `name`.

    The footer is read here, so a missing or unreadable file is refused at
    registration with the reader's own message and not later as an empty
    result. A flat schema only: a nested or repeated column is refused.
    """
    var footer = read_parquet_footer(path)
    var schema = footer.take_schema()
    session.catalog.add_parquet(name, path, schema^)


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
