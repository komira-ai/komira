"""`Session.add_sql_binding` on a library older than ABI 1.10, the stand-in
of ABI 1.2 (fake_libkomira.c), whose fake store records every credential
call:

- `komira.files` builds a source without loading any library;
- `add_sql_binding` raises `KomiraError` naming the call and the version it
  needs, and seals nothing: the fake store records no call, so a library that
  cannot bind never receives the source's secret;
- the session answers the next call: `_seal_credential` still seals there.

    test_sql_binding_minor.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_store/libkomira.so` is the stand-in.
"""

import ctypes
import os
import sys

import komira
from komira import AwsKeys, KomiraError, _native, files


def take(path):
    """The fake store's lines, read with the two-call protocol."""
    fn = ctypes.CDLL(path, mode=ctypes.RTLD_LOCAL).komira_fake_store
    fn.restype = ctypes.c_int32
    fn.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
    status, data = _native._two_call("komira_fake_store", fn)
    assert status == _native.KOMIRA_OK, status
    return data.decode("ascii").splitlines()


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    keys = AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="wJalrXUtnFEMI")
    source = files("s3://lake/a.parquet", credential=keys, region="eu-west-1")
    assert _native._loaded is None

    native = _native.load(os.path.join(lib_dir, "fake_store"))
    assert komira.abi_version() == 1002
    with komira.Session() as s:
        assert take(native.path) == []
        try:
            s.add_sql_binding("t", source)
        except KomiraError as e:
            assert type(e) is KomiraError, repr(e)
            assert str(e) == "komira_add_sql_binding needs libkomira ABI version 1.10; the library at {} is 1.2".format(
                native.path
            ), str(e)
            assert e.status is None, e.status
        else:
            raise AssertionError("add_sql_binding on ABI 1.2 raised nothing")
        assert take(native.path) == []
        s._seal_credential(keys)
        assert [line.split(" ")[0] for line in take(native.path)] == ["add", "set", "set", "seal"]
    print("sql_binding_minor: refused on libkomira {} before any seal".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
