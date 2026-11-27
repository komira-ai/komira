"""Any minor version of ABI major 1 loads: a 1.0 library, which lacks the
calls 1.1, 1.2 and 1.3 added, and a 1.3 library, which has the credential
calls of 1.2 and komira_sql_stream. A call the library's minor does not
include raises when it is used, never at load: on both, the registration
calls of 1.5 (komira_register_csv and komira_register_json) raise, naming
the call and both versions.

    test_minor.py --lib-dir <dir> --runtime-dir <dir> --fake <name> --version <n>

`<dir>/<name>/libkomira.so` is a stand-in of fake_libkomira.c reporting
version `<n>` (`--runtime-dir`, which the rule passes, is not read).
"""

import ctypes
import os
import sys

import komira
from komira import KomiraError
from komira import _arrow, _native
from komira._credentials import AMBIENT, GcpToken


def main(args):
    def arg(name):
        return args[args.index(name) + 1]

    # Absolute, since the paths the rule passes are relative to where the
    # action started, and the loader reports the absolute path.
    directory = os.path.abspath(os.path.join(arg("--lib-dir"), arg("--fake")))
    version = int(arg("--version"))
    native = _native.load(directory)
    assert native.abi_version == version, native.abi_version
    assert komira.abi_version() == version
    assert _native._FUNCTIONS["komira_sql_stream"][0] == 3
    assert _native._FUNCTIONS["komira_register_csv"][0] == 5
    assert _native._FUNCTIONS["komira_register_json"][0] == 5

    with komira.Session() as s:
        if version % 1000 == 0:
            path = os.path.join(directory, _native._LIB_NAME)
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
            # Sealing a credential needs the calls of 1.2; a built-in one
            # calls nothing, so it needs none.
            want = "komira_credential_add needs libkomira ABI version 1.2; the library at {} is 1.0".format(path)
            try:
                s._seal_credential(GcpToken("g", token="t"))
            except KomiraError as e:
                assert type(e) is KomiraError and str(e) == want and e.status is None, repr(e)
            else:
                raise AssertionError("a 1.0 library ran komira_credential_add")
            assert s._seal_credential(AMBIENT) is None
            want = "komira_sql_stream needs libkomira ABI version 1.3; the library at {} is 1.0".format(path)
            try:
                s.sql("rows")
            except KomiraError as e:
                assert type(e) is KomiraError and str(e) == want and e.status is None, repr(e)
            else:
                raise AssertionError("a 1.0 library ran komira_sql_stream")
        else:
            assert s.register_parquet("ok", "f.parquet") is None
            assert s._seal_credential(GcpToken("g", token="t")) is None
            # A 1.3 library binds komira_sql_stream: the stand-in fills a
            # stream, released here (this test has no pyarrow, which
            # Session.sql hands the stream to; sql_fake_test covers that).
            stream = native.sql_stream(s._ctx, "rows")
            assert stream.release and stream.get_next
            _arrow._Release(stream.release)(ctypes.addressof(stream))
            assert not stream.release
        # Neither stand-in has komira_ctx_new_with_options (1.4): naming an
        # option raises, naming the call and both versions, with no status;
        # naming none calls komira_ctx_new and works.
        want = "komira_ctx_new_with_options needs libkomira ABI version 1.4; the library at {} is {}.{}".format(
            os.path.join(directory, _native._LIB_NAME), *divmod(version, 1000)
        )
        for options in ({"memory_limit": 1 << 20}, {"threads": 2}):
            try:
                komira.Session(**options)
            except KomiraError as e:
                assert type(e) is KomiraError and str(e) == want and e.status is None, repr(e)
            else:
                raise AssertionError("a {} library ran komira_ctx_new_with_options".format(version))
        komira.Session(threads=None, memory_limit=None).close()
        # Neither stand-in has the registration calls of 1.5: each raises
        # when it is used, naming the call and both versions, with no status.
        path = os.path.join(directory, _native._LIB_NAME)
        have = "{}.{}".format(*divmod(version, 1000))
        for op, call in (
            ("komira_register_csv", lambda: s.register_csv("c", "c.csv")),
            ("komira_register_json", lambda: s.register_json("j", "j.jsonl")),
        ):
            want = "{} needs libkomira ABI version 1.5; the library at {} is {}".format(op, path, have)
            try:
                call()
            except KomiraError as e:
                assert type(e) is KomiraError and str(e) == want and e.status is None, repr(e)
            else:
                raise AssertionError("a {} library ran {}".format(have, op))
    print("minor: libkomira {} loaded".format(version))


if __name__ == "__main__":
    main(sys.argv[1:])
