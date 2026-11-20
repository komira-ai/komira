"""Any minor version of ABI major 1 loads: a 1.0 library, which lacks the
calls 1.1 added, and a 1.3 library, which lacks komira_sql_stream like every
library of today. A call the library's minor does not include raises when it
is used, never at load.

    test_minor.py --lib-dir <dir> --runtime-dir <dir> --fake <name> --version <n>

`<dir>/<name>/libkomira.so` is a stand-in of fake_libkomira.c reporting
version `<n>`.
"""

import os
import sys

import komira
from komira import KomiraError
from komira import _native


def main(args):
    def arg(name):
        return args[args.index(name) + 1]

    directory = os.path.join(arg("--lib-dir"), arg("--fake"))
    version = int(arg("--version"))
    native = _native.load(directory, search_path=[arg("--runtime-dir")])
    assert native.abi_version == version, native.abi_version
    assert komira.abi_version() == version
    assert "komira_sql_stream" not in _native._FUNCTIONS

    with komira.Session() as s:
        if version % 1000 == 0:
            path = os.path.join(directory, "libkomira.so")
            want = "komira_register_parquet needs libkomira ABI version 1.1; the library at {} is 1.0".format(path)
            try:
                s.register_parquet("ok", "f.parquet")
            except KomiraError as e:
                assert type(e) is KomiraError and str(e) == want and e.status is None, repr(e)
            else:
                raise AssertionError("a 1.0 library ran komira_register_parquet")
            ctx = native.ctx_new()
            for call in (
                lambda: native.parquet_schema(ctx, "p"),
                lambda: native.csv_binding(ctx, "c", delimiter=",", has_header=True, all_varchar=True),
                lambda: native.json_binding(ctx, "j"),
                lambda: native.plan_render(ctx, b""),
            ):
                try:
                    call()
                except KomiraError as e:
                    assert "needs libkomira ABI version 1.1; the library at {} is 1.0".format(path) in str(e), str(e)
                else:
                    raise AssertionError("a 1.0 library ran a 1.1 call")
            native.ctx_free(ctx)
        else:
            assert s.register_parquet("ok", "f.parquet") is None
    print("minor: libkomira {} loaded".format(version))


if __name__ == "__main__":
    main(sys.argv[1:])
