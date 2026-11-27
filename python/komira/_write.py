"""The write terminals' shared steps: a plan written to a file through the plan
door (docs/design/credentials_and_writes.md, section 10).

`write` wraps a plan in a `Write` root, encodes it and runs it on a session;
`destination`, `text_codec` and `parquet_codec` check a terminal's arguments
and name the path and the codec the engine is given, before the library is
called. The frame's terminals (komira/_frame.py) use them with pandas' own
parameter names.

The engine writes the file all or nothing, and refuses a destination that is a
URL (`STORAGE_URL_REFUSED`) or a codec the format does not take by name.
"""

from __future__ import annotations

import os
from collections.abc import Mapping

from . import _ops
from ._errors import UnsupportedOperation
from ._session import Session, _local_path

__all__ = ["destination", "parquet_codec", "text_codec", "write"]

# Each suffix the `compression="infer"` of pandas reads, as the name of the
# compression it means; the longer suffixes of an archive come first.
_INFERRED = (
    (".tar.gz", "tar"),
    (".tar.xz", "tar"),
    (".tar.bz2", "tar"),
    (".tar", "tar"),
    (".gz", "gzip"),
    (".zst", "zstd"),
    (".bz2", "bz2"),
    (".zip", "zip"),
    (".xz", "xz"),
)
_TEXT_NAMES = ("gzip", "zstd")
_REFUSED_NAMES = ("bz2", "zip", "xz", "tar")
_PARQUET_NAMES = ("snappy", "gzip", "zstd", "lz4")


def write(
    session: Session,
    plan: _ops.Plan,
    sources: Mapping[str, object],
    path: str,
    fmt: str,
    codec: str | None,
) -> None:
    """Runs `plan` (reading `sources`) on `session` and writes its rows to
    `path` as `fmt`, one of `_ops.WRITE_FORMATS`, compressed with `codec`
    (None for the format's default). Returns once the file is complete; a
    refusal of the engine raises its error."""
    from . import _plan

    root = _ops.Write(plan, _ops.WriteTarget(path, fmt, codec))
    session._plan_write(_plan.encode_plan(root, sources).SerializeToString())


def destination(path: object, verb: str) -> str:
    """The path a `verb` writes to. `None` is refused, since pandas returns the
    file's contents for it. A `str` with `://` is returned as it is, for the
    engine to refuse by name; any other path has `~` expanded and is made
    absolute against the working directory now."""
    if path is None:
        raise UnsupportedOperation(
            f"{verb}(None) returns the file's contents instead of writing it, which komira does not: "
            "pass a file path"
        )
    if isinstance(path, os.PathLike):
        path = os.fspath(path)
    if isinstance(path, str) and "://" in path:
        return path
    return _local_path(path)


def _refused_text(verb: str, name: str, inferred_from: str | None) -> UnsupportedOperation:
    if inferred_from is None:
        return UnsupportedOperation(
            f"{verb}(compression={name!r}) writes a {name} file, which komira does not write: "
            "use compression='gzip', 'zstd' or None"
        )
    return UnsupportedOperation(
        f"{verb}(compression='infer') reads {name!r} from the extension of {inferred_from!r}, "
        f"and komira does not write a {name} file: pass compression='gzip', 'zstd' or None"
    )


def text_codec(compression: object, dest: str, verb: str) -> str:
    """The codec of a CSV or JSON file a `verb` writes to `dest`, for pandas'
    `compression`: "infer" reads `dest`'s extension (`.gz` gzip, `.zst` zstd,
    else none), None is none, "gzip" and "zstd" are themselves. Other
    compressions pandas writes are refused by name, as is a dict."""
    if compression is None:
        return "uncompressed"
    if isinstance(compression, str):
        if compression in _TEXT_NAMES:
            return compression
        if compression in _REFUSED_NAMES:
            raise _refused_text(verb, compression, None)
        if compression == "infer":
            lowered = dest.lower()
            for suffix, name in _INFERRED:
                if lowered.endswith(suffix):
                    if name in _TEXT_NAMES:
                        return name
                    raise _refused_text(verb, name, dest)
            return "uncompressed"
        raise UnsupportedOperation(
            f"{verb}(compression={compression!r}) is not a compression komira writes: "
            "use 'infer', 'gzip', 'zstd' or None"
        )
    if isinstance(compression, Mapping):
        raise UnsupportedOperation(
            f"{verb}(compression={{...}}) takes the compression's options, and komira takes only its name: "
            "pass compression='gzip', 'zstd' or None"
        )
    raise TypeError(f"{verb} compression must be a str or None, not {type(compression).__name__}")


def parquet_codec(compression: object) -> str:
    """The codec of a Parquet file for `to_parquet`'s `compression`: "snappy",
    "gzip", "zstd" and "lz4" are themselves, None is none; any other is refused."""
    if compression is None:
        return "uncompressed"
    if isinstance(compression, str):
        if compression in _PARQUET_NAMES:
            return compression
        raise UnsupportedOperation(
            f"to_parquet(compression={compression!r}) is not a codec komira writes: "
            "use 'snappy', 'gzip', 'zstd', 'lz4' or None"
        )
    raise TypeError(f"to_parquet compression must be a str or None, not {type(compression).__name__}")
