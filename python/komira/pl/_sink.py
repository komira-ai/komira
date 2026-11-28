"""The argument checks of komira.pl's write terminals, `sink_csv`,
`sink_parquet` and `sink_ndjson` (komira/pl/_frame.py), with polars' own
parameter names and defaults.

Each check returns what the engine is given, the destination and the codec, or
raises before the library is called: a value komira writes otherwise is
refused by name with `UnsupportedOperation` (komira/_write.py, `unsupported`),
a value of the wrong type with `TypeError`. A keyword polars has and these do
not take is Python's own `TypeError`.
"""

from __future__ import annotations

import os

from komira import _write
from komira._errors import UnsupportedOperation

__all__ = ["csv_options", "destination", "parquet_codec", "text_codec", "write_options"]

_TEXT_NAMES = ("uncompressed", "gzip", "zstd")
_PARQUET_NAMES = ("zstd", "snappy", "gzip", "lz4", "uncompressed")


def destination(verb: str, path: object) -> str:
    """The path a `verb` writes to: a `str` or `os.PathLike[str]`, made
    absolute now (komira/_write.py, `destination`). A file object, which
    polars writes into, is refused; any other value is a `TypeError`."""
    if path is None:
        raise TypeError("path must be a str or os.PathLike[str], not NoneType")
    if not isinstance(path, (str, os.PathLike)) and hasattr(path, "write"):
        raise UnsupportedOperation(
            f"{verb}() of a {type(path).__name__} is not supported: komira writes to a file path, "
            "not into a file object"
        )
    return _write.destination(path, verb)


def _flag(verb: str, name: str, value: object) -> bool:
    if not isinstance(value, bool):
        raise TypeError(f"{verb} {name} must be a bool, not {type(value).__name__}")
    return value


def write_options(verb: str, compression_level: object, maintain_order: object, mkdir: object, lazy: object) -> None:
    """The keywords every sink takes. `maintain_order` is honoured either way:
    an ordered frame is written in its order, and False only allows another."""
    if compression_level is not None:
        raise _write.unsupported(
            verb, "compression_level", compression_level, "komira writes each codec at its default level"
        )
    _flag(verb, "maintain_order", maintain_order)
    if _flag(verb, "mkdir", mkdir):
        raise _write.unsupported(verb, "mkdir", True, "komira writes into a directory that exists")
    if _flag(verb, "lazy", lazy):
        raise _write.unsupported(verb, "lazy", True, "komira writes the file at the call and returns None")


def csv_options(
    include_header: object,
    separator: object,
    line_terminator: object,
    quote_char: object,
    null_value: object,
    include_bom: object,
) -> None:
    """The CSV keywords of `sink_csv`: each is taken at the value komira's CSV
    writer writes, which is polars' default (`null_value` also as "")."""
    if not _flag("sink_csv", "include_header", include_header):
        raise _write.unsupported("sink_csv", "include_header", False, _write.ALWAYS_HEADER)
    if separator != ",":
        raise _write.unsupported("sink_csv", "separator", separator, _write.COMMA)
    if line_terminator != "\n":
        raise _write.unsupported("sink_csv", "line_terminator", line_terminator, "komira ends each line with '\\n'")
    if quote_char != '"':
        raise _write.unsupported("sink_csv", "quote_char", quote_char, "komira quotes a cell with '\"'")
    if null_value is not None and null_value != "":
        raise _write.unsupported("sink_csv", "null_value", null_value, "komira writes NULL as an empty cell")
    if _flag("sink_csv", "include_bom", include_bom):
        raise _write.unsupported("sink_csv", "include_bom", True, "komira writes no byte order mark")


def text_codec(verb: str, compression: object) -> str:
    """The codec of a CSV or NDJSON file for polars' `compression`:
    "uncompressed", "gzip" or "zstd". The file's extension is not read."""
    if not isinstance(compression, str):
        raise TypeError(f"{verb} compression must be a str, not {type(compression).__name__}")
    if compression not in _TEXT_NAMES:
        raise _write.unsupported(
            verb, "compression", compression, "komira writes 'uncompressed', 'gzip' or 'zstd'"
        )
    return compression


def parquet_codec(compression: object) -> str:
    """The codec of a Parquet file for polars' `compression`: "zstd",
    "snappy", "gzip", "lz4" or "uncompressed"."""
    if not isinstance(compression, str):
        raise TypeError(f"sink_parquet compression must be a str, not {type(compression).__name__}")
    if compression not in _PARQUET_NAMES:
        raise _write.unsupported(
            "sink_parquet",
            "compression",
            compression,
            "komira writes 'zstd', 'snappy', 'gzip', 'lz4' or 'uncompressed'",
        )
    return compression
