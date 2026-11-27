"""The CSV skip (the number of lines skipped before the header) on the
stand-ins of ABI 1.11 and 1.10 (fake_libkomira.c):

- on 1.11, a skip above 0 reaches komira_csv_binding_with_skip and
  komira_register_csv_with_skip with the skip as given, whether it is passed to
  `Native` or to `Session.register_csv`, and a skip of 0 reaches the calls
  `Native` made before ABI 1.11;
- on 1.10, a skip of 0 is served by those same calls, and a skip above 0
  raises KomiraError naming the call and ABI 1.11 and reaches no call;
- on both, a boolean, a non-integer and a negative skip are refused before
  any call, with the call log unchanged.

    test_csv_skip.py --lib-dir <dir> --runtime-dir <dir> --fake <name> --version <n>

`<dir>/<name>/libkomira.so` is a stand-in of fake_libkomira.c reporting
version `<n>` (`--runtime-dir`, which the rule passes, is not read).
"""

import ctypes
import os
import sys

import komira
from komira import KomiraError, _native


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def main(args):
    def arg(name):
        return args[args.index(name) + 1]

    directory = os.path.abspath(os.path.join(arg("--lib-dir"), arg("--fake")))
    version = int(arg("--version"))
    native = _native.load(directory)
    assert native.abi_version == version, native.abi_version
    assert _native._FUNCTIONS["komira_csv_binding_with_skip"][0] == 11
    assert _native._FUNCTIONS["komira_register_csv_with_skip"][0] == 11
    assert native.has("komira_csv_binding_with_skip") == (version == 1011)
    assert native.has("komira_register_csv_with_skip") == (version == 1011)

    fake = ctypes.CDLL(native.path, mode=ctypes.RTLD_LOCAL)
    fake.komira_fake_register_csv_log.restype = ctypes.c_char_p

    def log():
        return fake.komira_fake_register_csv_log().decode("ascii")

    ctx = native.ctx_new()
    assert native.register_parquet(ctx, "ok", "f.parquet") is None

    # A skip of 0 is the call of before ABI 1.11, whichever library this is.
    got = native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False)
    assert got == b"csv:c.csv:59:1:0", got
    got = native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=0)
    assert got == b"csv:c.csv:59:1:0", got
    assert native.register_csv(ctx, "ok", "c.csv", delimiter=",", header=True, all_varchar=False, skip=0) is None
    assert log() == "csv;", log()

    def refused_before_any_call(skip, cls, message):
        before = log()
        kw = {"delimiter": ",", "all_varchar": False, "skip": skip}
        e = raised(lambda: native.csv_binding(ctx, "c.csv", has_header=True, **kw))
        assert type(e) is cls and str(e) == message, repr(e)
        e = raised(lambda: native.register_csv(ctx, "ok", "c.csv", header=True, **kw))
        assert type(e) is cls and str(e) == message, repr(e)
        assert log() == before, log()

    refused_before_any_call(True, TypeError, "skip must be an int, not bool")
    refused_before_any_call("1", TypeError, "skip must be an int, not str")
    refused_before_any_call(1.0, TypeError, "skip must be an int, not float")
    refused_before_any_call(-1, ValueError, "skip must be 0 or more, and fit in 64 bits, not -1")
    refused_before_any_call(2**63, ValueError, "skip must be 0 or more, and fit in 64 bits, not {}".format(2**63))

    if version == 1011:
        got = native.csv_binding(ctx, "c.csv", delimiter=";", has_header=True, all_varchar=False, skip=2)
        assert got == b"csv:c.csv:59:1:0:2", got
        got = native.csv_binding(ctx, "c.csv", delimiter=",", has_header=False, all_varchar=True, skip=2**63 - 1)
        assert got == b"csv:c.csv:44:0:1:9223372036854775807", got
        assert native.register_csv(ctx, "ok", "c.csv", delimiter=",", header=True, all_varchar=False, skip=3) is None
        assert log() == "csv;skip=3;", log()
        with komira.Session() as s:
            assert s.register_csv("ok", "c.csv", skip=5) is None
            assert s.register_csv("ok", "c.csv") is None
        assert log() == "csv;skip=3;skip=5;csv;", log()
    else:
        path = os.path.join(directory, _native._LIB_NAME)
        needs = "{} needs libkomira ABI version 1.11; the library at {} is 1.10"
        for name, call in (
            (
                "komira_csv_binding_with_skip",
                lambda: native.csv_binding(ctx, "c.csv", delimiter=",", has_header=True, all_varchar=False, skip=2),
            ),
            (
                "komira_register_csv_with_skip",
                lambda: native.register_csv(ctx, "ok", "c.csv", delimiter=",", header=True, all_varchar=False, skip=3),
            ),
        ):
            e = raised(call)
            assert type(e) is KomiraError and str(e) == needs.format(name, path), repr(e)
            assert e.status is None, e.status
        with komira.Session() as s:
            e = raised(lambda: s.register_csv("ok", "c.csv", skip=1))
            assert type(e) is KomiraError and str(e) == needs.format("komira_register_csv_with_skip", path), repr(e)
            assert s.register_csv("ok", "c.csv") is None
        assert log() == "csv;csv;", log()
    print("csv_skip: libkomira {} serves the CSV skip as the library allows".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
