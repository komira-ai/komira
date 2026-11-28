"""Scan leaves: what a scan reads, as libkomira describes the file.

The encoder never types a file itself. A scan's columns and how the engine
identifies the file come from libkomira, which reads them with the engine's
own readers:

    parquet_source   the `WireSchema` bytes of `komira_parquet_schema`, put
                     in a `WireParquetSource` of one local path, as the SQL
                     catalog binds a registered file (no name, mtime 0)
    parquet_files_source
                     the `WireParquetSource` bytes of `komira_parquet_source`,
                     whole: the files a glob or a directory names, sorted,
                     their schema and their Hive partition columns, which the
                     scan reads after the files' columns (`scan_schema`)
    binding_source   the `WireScanBinding` bytes of `komira_csv_binding` or
                     `komira_json_binding`, whole: its fingerprint and
                     snapshot token are the file's identity

`encode_plan` takes these keyed by the scan's path. A `Scan` names its columns
and their types itself; `encode_scan` checks them against the source, column
for column, so a plan is never sent with a schema the file does not have.
"""

from __future__ import annotations

from collections.abc import Mapping

from komira._errors import UnsupportedOperation
from komira._ops._rel import Scan

from ._wire import arrow_name, member, pb, vocab

__all__ = ["binding_source", "encode_scan", "parquet_files_source", "parquet_source", "scan_schema"]

# The binding variants a scan of each non-Parquet format reads
# (`SourceVariantTag`, src/plan_proto/plan_vocabulary.proto).
_FORMAT_VARIANTS = {
    "csv": ("csv",),
    "json": ("json",),
    "ndjson": ("json",),
    "orc": ("orc",),
    "avro": ("avro",),
    "arrow": ("arrow_uncompressed", "arrow_lz4_frame", "arrow_zstd"),
}

_LAYOUTS = (vocab.SOURCE_KIND_COLUMNAR, vocab.SOURCE_KIND_ROW)


def _need_bytes(value: object, what: str) -> bytes:
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise TypeError(f"{what} must be bytes, not {type(value).__name__}")
    return bytes(value)


def parquet_source(path: str, schema: bytes) -> pb.WireScanSource:
    """The source of a scan of the Parquet file at `path`, whose schema is the
    `WireSchema` bytes `komira_parquet_schema` gave for it."""
    if not isinstance(path, str):
        raise TypeError(f"path must be a str, not {type(path).__name__}")
    if path == "":
        raise ValueError("path must not be empty")
    out = pb.WireScanSource()
    out.parquet.paths.append(path)
    out.parquet.schema.ParseFromString(_need_bytes(schema, "schema"))
    out.parquet.fs_is_local = True
    return out


def parquet_files_source(source: bytes) -> pb.WireScanSource:
    """The source of a scan of the Parquet files `komira_parquet_source`
    resolved, its `WireParquetSource` bytes `source` taken whole."""
    out = pb.WireScanSource()
    out.parquet.ParseFromString(_need_bytes(source, "source"))
    return out


def scan_schema(source: pb.WireScanSource) -> pb.WireSchema:
    """The columns a scan of the Parquet source `source` reads: the files'
    columns followed by its Hive partition columns."""
    if not source.parquet.partition_cols:
        return source.parquet.schema
    out = pb.WireSchema()
    out.CopyFrom(source.parquet.schema)
    out.fields.extend(source.parquet.partition_cols)
    return out


def binding_source(binding: bytes) -> pb.WireScanSource:
    """The source of a scan the `WireScanBinding` bytes `binding` describe."""
    out = pb.WireScanSource()
    out.binding.ParseFromString(_need_bytes(binding, "binding"))
    return out


def _source_of(node: Scan, sources: Mapping[str, pb.WireScanSource]) -> pb.WireScanSource:
    if node.path not in sources:
        raise KeyError(
            f"no source for the scan of '{node.path}'; the sources are for: "
            + ", ".join(sorted(sources))
        )
    source = sources[node.path]
    if not isinstance(source, pb.WireScanSource):
        raise TypeError(
            f"the source of '{node.path}' must be a WireScanSource, not {type(source).__name__}"
        )
    return source


def _schema_and_layout(node: Scan, source: pb.WireScanSource) -> tuple[pb.WireSchema, int]:
    """The schema a scan reads and the layout (`SourceOrientation`) the engine
    gives it: columnar for Parquet, the binding's declared one otherwise."""
    arm = source.WhichOneof("payload")
    if arm == "parquet":
        if node.format != "parquet":
            raise ValueError(f"the scan of '{node.path}' is {node.format}, and its source is Parquet")
        return scan_schema(source), vocab.SOURCE_KIND_COLUMNAR
    if arm == "binding":
        binding = source.binding
        variants = _FORMAT_VARIANTS.get(node.format, ())
        if binding.variant_tag not in [member("SOURCE_VARIANT_", v) for v in variants]:
            raise ValueError(
                f"the scan of '{node.path}' is {node.format}, and its source is a "
                f"binding of kind '{binding.kind_name}'"
            )
        if binding.orientation not in _LAYOUTS:
            raise UnsupportedOperation(
                f"the binding of '{node.path}' declares no columnar or row layout "
                f"(orientation {binding.orientation}), so its scan cannot be encoded"
            )
        return binding.schema, binding.orientation
    raise ValueError(f"the source of '{node.path}' holds neither a Parquet file nor a binding")


def _check_declared(node: Scan, schema: pb.WireSchema) -> None:
    """A scan's declared columns are the source's: the same names in the same
    order, each with the name of its Arrow type."""
    declared = [(f.name, f.dtype) for f in node.schema]
    actual = [(f.name, arrow_name(f.arrow_type_id)) for f in schema.fields]
    if declared != actual:
        raise ValueError(
            f"the scan of '{node.path}' declares the columns "
            + ", ".join(f"{n} {t}" for n, t in declared)
            + "; the file has "
            + ", ".join(f"{n} {t}" for n, t in actual)
        )


def encode_scan(node: Scan, sources: Mapping[str, pb.WireScanSource]) -> pb.WirePlan:
    """A scan leaf: the whole source schema, read with no projection, filter
    or row count, as the engine's scan of a registered file is built."""
    source = _source_of(node, sources)
    schema, layout = _schema_and_layout(node, source)
    _check_declared(node, schema)
    out = pb.WirePlan()
    out.output_schema.fields.extend(schema.fields)
    out.scan.source.CopyFrom(source)
    out.scan.has_schema = True
    out.scan.schema.CopyFrom(schema)
    out.scan.source_kind = layout
    return out
