# =============================================================================
# plan_wire_parquet_source.mojo -- a resolved Parquet source as wire bytes.
# =============================================================================
#
# `parquet_source_to_bytes` is the producer-side twin of `schema_to_bytes` for
# a scan of many Parquet files. A frontend in another language that reads a
# glob or a directory needs the file list the engine resolved (sorted), the
# files' common schema and the Hive partition columns with each file's values;
# it cannot honestly compute the partition columns' types (the engine's
# autocast) or the schema's codes, so it takes the whole `WireParquetSource`
# from the engine and splices it into `WireScanSource.parquet`.
# =============================================================================

from proto_codec import encode_proto
from plan_proto.plan import WireParquetSource
from scan_source.parquet_source import ParquetSource

from .plan_wire_codec import _parquet_to_wire


def parquet_source_to_bytes(p: ParquetSource) raises -> List[UInt8]:
    """Encode a `ParquetSource` as bare `komira.plan.v1.WireParquetSource`
    bytes: its paths, data schema, partition columns and partition values.

    The data schema holds the files' columns only; a scan of the source reads
    those columns followed by the partition columns.

    Raises:
        What the codec raises for a source the format cannot carry: a lazy
        Hive scan or a partition predicate (`PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET`)
        and a non-local file system (`PLAN_WIRE_UNSUPPORTED_REMOTE_FS`).
    """
    return encode_proto[WireParquetSource](_parquet_to_wire(p))
