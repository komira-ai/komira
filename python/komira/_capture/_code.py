"""Where a captured function's code lives and how it reaches the runtime
(docs/design/optimized_plan_udfs.md section 10.6).

Only a module-level function of a module with a `.py` source file is captured.
The code is reached as

- `package`: the module belongs to an installed distribution (its file is under
  a `site-packages` or `dist-packages` directory of `sys.path`, and its top-level
  name is one `importlib.metadata.packages_distributions()` lists). The code
  digest list is empty: the environment holds the distribution.
- `bundle`: any other module, the user's own code, an editable install included.
  The bundle is a stored zip of the module's source at the path its dotted name
  gives, with the source of each parent package that has an `__init__.py` and a
  directory entry for each parent that has not (a namespace package). The code
  digest is the sha256 of the zip's bytes, which names the code object under
  the code root, and the runtime appends that zip to `sys.path`. The bundle
  holds the function's module and its parents only, not the modules it imports.

The zip is the same bytes for the same sources: names sorted, stored, a fixed
date, fixed permissions.
"""

from __future__ import annotations

import dataclasses
import hashlib
import importlib.metadata
import inspect
import io
import os
import sys
import tempfile
import zipfile

from komira._errors import KomiraError, UnsupportedOperation

_BUNDLE_DATE = (2026, 9, 1, 0, 0, 0)
_SITE_DIRECTORIES = ("site-packages", "dist-packages")


@dataclasses.dataclass(frozen=True)
class Location:
    """Where a function is defined: `module`, `qualname`, the source `origin`
    file and whether the module is a package's `__init__`."""

    module: str
    qualname: str
    origin: str
    is_package: bool

    @property
    def entry(self) -> str:
        return f"{self.module}:{self.qualname}"


def _refusal(name: str, why: str) -> UnsupportedOperation:
    return UnsupportedOperation(
        f"UDF_CAPTURE_UNSUPPORTED: `{name}` {why}. A UDF is a function defined at the top level of a "
        f".py module: move it to a module and import it"
    )


def _source_of(module_name):
    module = sys.modules.get(module_name)
    spec = getattr(module, "__spec__", None)
    origin = getattr(spec, "origin", None)
    if module is None or spec is None or not getattr(spec, "has_location", False):
        return module, None, False
    if not isinstance(origin, str) or not origin.endswith(".py") or not os.path.isfile(origin):
        return module, None, False
    return module, origin, spec.submodule_search_locations is not None


def locate(fn, owners) -> Location:
    """Where `fn` is defined, or the refusal. `owners` are the objects that may
    be the module's attribute at `fn`'s qualified name (the function and its
    `Udf`)."""
    if not inspect.isfunction(fn):
        raise _refusal(getattr(fn, "__qualname__", type(fn).__name__), f"is a {type(fn).__name__}, not a plain function")
    qualname = fn.__qualname__
    if fn.__name__ == "<lambda>":
        raise _refusal(qualname, "is a lambda")
    if "<locals>" in qualname:
        raise _refusal(qualname, "is nested inside another function")
    if "." in qualname:
        raise _refusal(qualname, "is defined inside a class")
    module_name = fn.__module__
    if module_name is None or module_name == "__main__":
        raise _refusal(qualname, "is defined in __main__")
    module, origin, is_package = _source_of(module_name)
    if origin is None:
        raise _refusal(qualname, f"is defined in module `{module_name}`, which has no .py source file")
    attribute = getattr(module, qualname, None)
    if not any(attribute is owner for owner in owners):
        raise _refusal(qualname, f"is not what `{module_name}.{qualname}` names")
    return Location(module_name, qualname, origin, is_package)


def _same_directory(path: str, directory: str) -> bool:
    path = os.path.realpath(path)
    directory = os.path.realpath(directory)
    return path.startswith(directory.rstrip(os.sep) + os.sep)


def is_installed(location: Location) -> bool:
    """Whether the module comes from an installed distribution."""
    top = location.module.split(".")[0]
    in_site = any(
        isinstance(entry, str)
        and os.path.basename(os.path.normpath(entry)) in _SITE_DIRECTORIES
        and _same_directory(location.origin, entry)
        for entry in sys.path
    )
    return in_site and top in importlib.metadata.packages_distributions()


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def bundle_files(location: Location) -> dict:
    """`{zip path: source bytes}` of the bundle; a path ending in `/` is a
    directory entry and holds `None`."""
    parts = location.module.split(".")
    files = {}
    for i in range(1, len(parts)):
        parent = ".".join(parts[:i])
        _, origin, is_package = _source_of(parent)
        directory = "/".join(parts[:i])
        if origin is not None and is_package and os.path.basename(origin) == "__init__.py":
            files[directory + "/__init__.py"] = _read(origin)
        else:
            files[directory + "/"] = None
    path = "/".join(parts)
    files[path + "/__init__.py" if location.is_package else path + ".py"] = _read(location.origin)
    return files


def make_zip(files: dict) -> bytes:
    """A stored zip of `files`, the same bytes for the same files."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name in sorted(files, key=lambda n: n.encode("utf-8")):
            info = zipfile.ZipInfo(name, date_time=_BUNDLE_DATE)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            data = files[name]
            if data is None:
                info.external_attr = (0o40755 << 16) | 0x10
                data = b""
            else:
                info.external_attr = 0o100644 << 16
            z.writestr(info, data)
    return buf.getvalue()


def code_of(location: Location):
    """`(form, code, objects)`: the form (`"package"` or `"bundle"`), the
    `(role, sha256)` pairs of the spec, and `{sha256: bytes}` of the code objects
    to write under the code root."""
    if is_installed(location):
        return "package", (), {}
    data = make_zip(bundle_files(location))
    digest = hashlib.sha256(data).digest()
    return "bundle", (("bundle", digest),), {digest: data}


# The code objects every captured function produced in this process,
# `{sha256: bytes}`: what a session writes under its code root for the
# UdfRefs of a plan.
_registry: dict = {}


def register_objects(objects: dict) -> None:
    """Remember `objects` (`{sha256: bytes}`) for `registered_object`."""
    _registry.update(objects)


def registered_object(digest: bytes):
    """The bytes of the captured code object with this sha256, or None."""
    return _registry.get(digest)


def write_objects(code_root, objects: dict) -> None:
    """Write each code object to `code_root/<sha256 hex>`: creates the
    directory, leaves a file that already holds the bytes, and refuses one
    that holds other bytes."""
    os.makedirs(code_root, exist_ok=True)
    for digest, data in objects.items():
        path = os.path.join(code_root, digest.hex())
        if os.path.exists(path):
            if _read(path) != data:
                raise KomiraError(f"the code object {path} already exists with other bytes")
            continue
        fd, temporary = tempfile.mkstemp(dir=code_root, prefix=".code-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        except BaseException:
            os.unlink(temporary)
            raise
