"""The exception table (komira/_errors.py) on the stand-ins of fake_libkomira.c:

- on an ABI 1.7 stand-in, whose komira_sql_stream answers
  `refuse <status> <step> [<code>]` with that status, step number and code:
  - every code of the table raises its class, with `status` -3, `code`, the
    message unchanged and `step` None when the refusal names no step;
  - the code is chosen before the step: SQL_NOT_SUPPORTED at the parse or the
    bind step is an UnsupportedOperation, with that step;
  - with no code, the parse step is a ParseError and the bind step a
    BindError, each with `code` None; the optimize, lower and execute steps
    are a plain KomiraError with `step` set;
  - an unknown code is a plain KomiraError that keeps the code; an unknown
    step number is `step` None, and does not pick a class;
  - a status of -2 or -5 is a plain KomiraError whatever the code and step,
    which it still carries;
  - a credential refusal is a CredentialsError with its code and the bind step;
  - the last error's code and step read as None when there is no error;
- on an ABI 1.3 stand-in, which has neither call: `code` and `step` are None,
  every refusal is a plain KomiraError, and a credential refusal a
  CredentialsError;
- every class is a KomiraError and a name of `komira.__all__`.

    test_errors.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_v1_7/libkomira.so` and `<dir>/fake_v1_3/libkomira.so` are the
stand-ins (`--runtime-dir`, which the rule passes, is not read). A process
holds one library, so the test clears the loader's record of the first before
it loads the second.
"""

import os
import sys

import komira
from komira import _errors, _native

PARSE, BIND, OPTIMIZE, LOWER, EXECUTE = 1, 2, 3, 4, 5

# The table, written out here from the design (docs/design/credentials_and_writes.md,
# section 11): class name -> its codes.
TABLE = {
    "ParseError": ["SQL_SYNTAX_ERROR"],
    "BindError": ["SQL_BIND_ERROR", "BIND_NAME_UNBOUND", "BIND_NOT_A_CATALOG", "BIND_SCOPE_NOT_A_TABLE", "BIND_VIEW_NOT_A_QUERY"],
    "UnsupportedOperation": [
        "SQL_NOT_SUPPORTED",
        "STATEMENT_NOT_A_QUERY",
        "OPTIMIZE_UNRESOLVED_SCALAR",
        "LOWERING_SINK_UNSERVED",
        "LOWERING_JOIN_UNSERVED",
        "LOWERING_WINDOW_UNSERVED",
        "LOWERING_UDF_UNSERVED",
        "SQL_STATEMENT_UNSUPPORTED",
        "COPY_OPTION_UNSUPPORTED",
        "COPY_FORMAT_NOT_INFERRED",
        "STORAGE_URL_REFUSED",
        "STORAGE_RANGE_NOT_SUPPORTED",
        "STORAGE_WRITE_UNSUPPORTED",
        "PLAN_URL_QUERY_REFUSED",
    ],
    "CredentialsError": [
        "CREDENTIAL_UNBOUND",
        "CREDENTIAL_NAME_CONFLICT",
        "CREDENTIAL_KIND_MISMATCH",
        "CREDENTIALS_NOT_FOUND",
        "CREDENTIALS_INVALID",
    ],
    "StorageError": [
        "STORAGE_REGION_UNKNOWN",
        "STORAGE_NOT_FOUND",
        "STORAGE_ACCESS_DENIED",
        "STORAGE_THROTTLED",
        "STORAGE_TRANSPORT",
        "STORAGE_MALFORMED",
        "STORAGE_OBJECT_CHANGED",
        "STORAGE_IO",
    ],
}

STEP_NAMES = {PARSE: "parse", BIND: "bind", OPTIMIZE: "optimize", LOWER: "lower", EXECUTE: "execute"}


def refusal(native, ctx, status, step, code=""):
    """The error komira_sql_stream raises when the stand-in refuses with
    `status`, step number `step` and `code`, and the message it carries."""
    text = "refuse {} {} {}".format(status, step, code).rstrip()
    message = "stand-in refusal status {} step {} code {}".format(status, step, code)
    try:
        native.sql_stream(ctx, text)
    except komira.KomiraError as e:
        assert str(e) == message, str(e)
        assert e.status == status, e.status
        return e
    raise AssertionError("the stand-in did not refuse " + text)


def check_classes():
    for name in list(TABLE) + ["LibraryLoadError", "UnsupportedCpuError"]:
        cls = getattr(_errors, name)
        assert issubclass(cls, komira.KomiraError), name
        assert name in komira.__all__, name
        assert getattr(komira, name) is cls, name
    assert "KomiraError" in komira.__all__
    assert set(_errors._CODE_CLASSES) == {code for codes in TABLE.values() for code in codes}
    # The function the loader calls, without a library.
    assert _errors.error_class(-3, "SQL_SYNTAX_ERROR", "bind") is komira.ParseError
    assert _errors.error_class(-3, None, "parse") is komira.ParseError
    assert _errors.error_class(-3, None, "lower") is komira.KomiraError
    assert _errors.error_class(-3, None, None, komira.CredentialsError) is komira.CredentialsError
    assert _errors.error_class(-3, None, "bind", komira.CredentialsError) is komira.BindError
    assert _errors.error_class(-2, "SQL_SYNTAX_ERROR", "parse", komira.CredentialsError) is komira.KomiraError
    e = komira.KomiraError("m")
    assert (e.status, e.code, e.step) == (None, None, None)


def check_v1_7(native):
    assert native.abi_version == 1007, native.abi_version
    ctx = native.ctx_new()

    # No error held: no code, no step.
    assert native.last_error_code(ctx) is None
    assert native.last_error_step(ctx) is None

    # Every code of the table raises its class; with no step, `step` is None.
    for name, codes in TABLE.items():
        for code in codes:
            e = refusal(native, ctx, -3, 0, code)
            assert type(e) is getattr(komira, name), (code, repr(e))
            assert (e.code, e.step) == (code, None), (e.code, e.step)

    # The code is chosen before the step.
    for step in (PARSE, BIND):
        e = refusal(native, ctx, -3, step, "SQL_NOT_SUPPORTED")
        assert type(e) is komira.UnsupportedOperation, repr(e)
        assert (e.code, e.step) == ("SQL_NOT_SUPPORTED", STEP_NAMES[step])
    e = refusal(native, ctx, -3, LOWER, "SQL_SYNTAX_ERROR")
    assert type(e) is komira.ParseError and e.step == "lower", repr(e)

    # With no code, the step: parse and bind have a class, the rest do not.
    e = refusal(native, ctx, -3, PARSE)
    assert type(e) is komira.ParseError and (e.code, e.step) == (None, "parse"), repr(e)
    e = refusal(native, ctx, -3, BIND)
    assert type(e) is komira.BindError and (e.code, e.step) == (None, "bind"), repr(e)
    for step in (OPTIMIZE, LOWER, EXECUTE):
        e = refusal(native, ctx, -3, step)
        assert type(e) is komira.KomiraError and (e.code, e.step) == (None, STEP_NAMES[step]), repr(e)
    e = refusal(native, ctx, -3, 0)
    assert type(e) is komira.KomiraError and (e.code, e.step) == (None, None), repr(e)

    # An unknown code keeps its spelling; an unknown step number is no step.
    e = refusal(native, ctx, -3, 0, "SOME_FUTURE_CODE")
    assert type(e) is komira.KomiraError and (e.code, e.step) == ("SOME_FUTURE_CODE", None), repr(e)
    e = refusal(native, ctx, -3, 9)
    assert type(e) is komira.KomiraError and (e.code, e.step) == (None, None), repr(e)
    e = refusal(native, ctx, -3, 9, "SQL_SYNTAX_ERROR")
    assert type(e) is komira.ParseError and (e.code, e.step) == ("SQL_SYNTAX_ERROR", None), repr(e)

    # Only an engine refusal is classified; the code and step stay readable.
    for status in (-2, -5):
        e = refusal(native, ctx, status, PARSE, "SQL_SYNTAX_ERROR")
        assert type(e) is komira.KomiraError and (e.code, e.step) == ("SQL_SYNTAX_ERROR", "parse"), repr(e)

    # The calls read the held error without clearing it.
    assert native.last_error_code(ctx) == "SQL_SYNTAX_ERROR"
    assert native.last_error_step(ctx) == "parse"
    assert native.last_error_code(ctx) == "SQL_SYNTAX_ERROR"

    # A credential refusal: the library's code and the bind step.
    try:
        native.credential_add(ctx, 1, "refuse_add")
    except komira.KomiraError as e:
        assert type(e) is komira.CredentialsError, repr(e)
        assert str(e) == "CREDENTIALS_INVALID: add: the stand-in refuses kind 1", str(e)
        assert (e.status, e.code, e.step) == (-3, "CREDENTIALS_INVALID", "bind"), (e.status, e.code, e.step)
    else:
        raise AssertionError("the stand-in did not refuse the credential")

    # A call that succeeds clears the code and the step with the message.
    assert native.credential_add(ctx, 1, "fine") > 0
    assert native.last_error(ctx) == ""
    assert native.last_error_code(ctx) is None
    assert native.last_error_step(ctx) is None
    native.ctx_free(ctx)


def check_v1_3(native):
    assert native.abi_version == 1003, native.abi_version
    ctx = native.ctx_new()
    assert native.last_error_code(ctx) is None
    assert native.last_error_step(ctx) is None
    for step, code in [(PARSE, "SQL_SYNTAX_ERROR"), (BIND, "SQL_BIND_ERROR"), (BIND, ""), (LOWER, "LOWERING_WINDOW_UNSERVED")]:
        e = refusal(native, ctx, -3, step, code)
        assert type(e) is komira.KomiraError and (e.code, e.step) == (None, None), repr(e)
        assert native.last_error_code(ctx) is None and native.last_error_step(ctx) is None
    try:
        native.credential_add(ctx, 1, "refuse_add")
    except komira.KomiraError as e:
        assert type(e) is komira.CredentialsError, repr(e)
        assert str(e) == "CREDENTIALS_INVALID: add: the stand-in refuses kind 1", str(e)
        assert (e.status, e.code, e.step) == (-3, None, None), (e.status, e.code, e.step)
    else:
        raise AssertionError("the stand-in did not refuse the credential")
    native.ctx_free(ctx)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    check_classes()
    for fake, check in (("fake_v1_7", check_v1_7), ("fake_v1_3", check_v1_3)):
        _native._loaded = None
        _native._loaded_dir = None
        check(_native.load(os.path.join(lib_dir, fake)))
    print("errors: the exception table maps each code and step, and a 1.3 library gives neither")


if __name__ == "__main__":
    main(sys.argv[1:])
