"""The wheel the wheel rule writes, read with the standard library alone.

The script reads the `[release]` directory of a wheel_package target and its
`[twin]` (the same wheel built again by a second action) and holds:

- the directory is exactly manifest.json, METADATA and the wheel, and the
  manifest is the PYTHON artifact manifest of that wheel (its sha256);
- the wheel's file name and WHEEL carry the tag given, and the version is the
  compiler version and the stamp given;
- the twin is the same bytes;
- RECORD lists every member once, with the sha256 and size of its bytes;
- METADATA names the distribution, its licence expression and files, and its
  Requires-Dist are exactly pyarrow, mojo-compiler at the compiler version, and
  the two extras; the METADATA beside the manifest is the same bytes;
- the licence members are the repository's LICENSE and NOTICE, byte for byte;
- the package's py.typed and libkomira (executable) are there with native
  owners beside it, and no library of the Mojo runtime is.
"""

import base64
import csv
import email.message
import email.parser
import hashlib
import io
import json
import os
import sys
import zipfile

RUNTIME_LIBS = {
    "libAsyncRTRuntimeGlobals.so",
    "libKGENCompilerRTShared.so",
    "libMSupportGlobals.so",
    "libgcc_s.so.1",
    "libstdc++.so.6",
}


def arg(argv: list[str], name: str) -> str:
    return argv[argv.index(name) + 1]


def read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def record_hash(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def headers(text: bytes) -> email.message.Message:
    return email.parser.BytesHeaderParser().parsebytes(text)


def main(argv: list[str]) -> None:
    release = arg(argv, "--release")
    twin = arg(argv, "--twin")
    tag = arg(argv, "--tag")
    version = arg(argv, "--compiler-version") + ".post" + arg(argv, "--stamp")
    platform = arg(argv, "--platform")

    name = f"komira-{version}-{tag}.whl"
    files = sorted(os.listdir(release))
    assert files == sorted(["METADATA", "manifest.json", name]), f"release holds {files}, want manifest.json, METADATA and {name}"
    wheel = read(os.path.join(release, name))
    assert read(twin) == wheel, f"the twin build is not the same bytes as {name}"

    manifest = json.loads(read(os.path.join(release, "manifest.json")))
    want = {
        "format": "kci.artifact_manifest",
        "schema_version": 1,
        "artifact_type": "PYTHON",
        "name": "komira",
        "version": version,
        "platform": platform,
        "file": name,
        "sha256": hashlib.sha256(wheel).hexdigest(),
        "metadata": "METADATA",
    }
    assert manifest == want, f"manifest.json is {manifest}, want {want}"

    info = f"komira-{version}.dist-info"
    with zipfile.ZipFile(io.BytesIO(wheel)) as z:
        entries = z.infolist()
        names = [e.filename for e in entries]
        assert len(names) == len(set(names)), f"a member is in the wheel twice: {names}"
        assert names[-1] == f"{info}/RECORD", f"the last member is {names[-1]}, not RECORD"
        data = {n: z.read(n) for n in names}
        modes = {e.filename: (e.external_attr >> 16) & 0o777 for e in entries}

    rows = list(csv.reader(io.StringIO(data[f"{info}/RECORD"].decode())))
    listed = [r[0] for r in rows]
    assert sorted(listed) == sorted(names), f"RECORD lists {listed}, the wheel holds {names}"
    for path, digest, size in rows:
        if path == f"{info}/RECORD":
            assert (digest, size) == ("", ""), f"RECORD gives itself a hash or size: {digest!r} {size!r}"
            continue
        assert digest == record_hash(data[path]), f"RECORD hash of {path} is {digest}, its bytes hash to {record_hash(data[path])}"
        assert size == str(len(data[path])), f"RECORD size of {path} is {size}, it holds {len(data[path])} bytes"

    wheel_meta = headers(data[f"{info}/WHEEL"])
    assert wheel_meta.get_all("Tag") == [tag], f"WHEEL tags are {wheel_meta.get_all('Tag')}, want [{tag}]"
    assert wheel_meta["Wheel-Version"] == "1.0", wheel_meta["Wheel-Version"]
    assert wheel_meta["Root-Is-Purelib"] == "false", wheel_meta["Root-Is-Purelib"]

    meta_bytes = data[f"{info}/METADATA"]
    assert read(os.path.join(release, "METADATA")) == meta_bytes, "the METADATA beside the manifest differs from the wheel's"
    meta = headers(meta_bytes)
    assert meta["Metadata-Version"] == "2.4", meta["Metadata-Version"]
    assert meta["Name"] == "komira", meta["Name"]
    assert meta["Version"] == version, f"Version is {meta['Version']}, want {version}"
    assert meta["License-Expression"] == "Apache-2.0", meta["License-Expression"]
    assert meta.get_all("License-File") == ["LICENSE", "NOTICE"], meta.get_all("License-File")
    assert meta["Requires-Python"] == ">=3.13", meta["Requires-Python"]
    requires = meta.get_all("Requires-Dist")
    want_requires = [
        "pyarrow",
        f"mojo-compiler=={arg(argv, '--runtime-pin')}",
        'pandas; extra == "pandas"',
        'polars; extra == "polars"',
    ]
    assert requires == want_requires, f"Requires-Dist is {requires}, want {want_requires}"
    assert meta.get_all("Provides-Extra") == ["pandas", "polars"], meta.get_all("Provides-Extra")
    assert all(not c.startswith("License ::") for c in meta.get_all("Classifier")), "a License classifier beside the expression"

    for member, path in [("LICENSE", arg(argv, "--license")), ("NOTICE", arg(argv, "--notice"))]:
        got = data.get(f"{info}/licenses/{member}")
        assert got == read(path), f"{info}/licenses/{member} is not the repository's {member}"

    assert "komira/py.typed" in data, "the wheel has no komira/py.typed"
    assert "komira/__init__.py" in data, "the wheel has no komira/__init__.py"
    assert modes.get("komira/_lib/libkomira.so") == 0o755, f"komira/_lib/libkomira.so mode {modes.get('komira/_lib/libkomira.so')}"
    owners = [n for n in names if n.startswith("komira/_lib/lib/libkomira_") and n.endswith("_native.so.1")]
    assert owners, "the wheel carries no native owner beside libkomira"
    carried = [n for n in names if n.rsplit("/", 1)[-1] in RUNTIME_LIBS]
    assert not carried, f"the wheel carries runtime libraries {carried}"


if __name__ == "__main__":
    main(sys.argv[1:])
