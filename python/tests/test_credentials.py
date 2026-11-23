"""Credential objects (komira/_credentials.py) and `Session._seal_credential`
on the stand-in's fake store (fake_libkomira.c, built as ABI 1.2).

What a credential holds and refuses before any library call: the name's
grammar and reserved names, each field's type, emptiness, UTF-8 and 4096-byte
bound, `repr` with every secret as `<set>`, and no pickle or copy. Then what
sealing one sends the library, read back from the fake store line by line:
the kind, the name, each field and the exact bytes of its value, in order,
and the session scope; nothing for `AMBIENT` and `ANONYMOUS`; and how each
failed call is raised: an engine refusal as `CredentialsError` with the
library's message, every other failure as a plain `KomiraError`.

    test_credentials.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_store/libkomira.so` is the stand-in (`--runtime-dir`, which the
rule passes, is not read).
"""

import copy
import ctypes
import os
import pathlib
import pickle
import sys

import komira
from komira import KomiraError, _native
from komira._credentials import (
    AMBIENT,
    ANONYMOUS,
    AwsKeys,
    AwsProfile,
    AzureKey,
    AzureSas,
    BearerToken,
    GcpServiceAccount,
    GcpToken,
    OAuth2ClientCredentials,
)
from komira._errors import CredentialsError

NAME_GRAMMAR = "a credential name must be 1 to 128 ASCII letters, digits, '_', '.' or '-'"
RESERVED = "the credential names ambient and anonymous are reserved: use komira.AMBIENT or komira.ANONYMOUS"
NOT_COPIED = "a komira credential cannot be pickled or copied: it holds a secret"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def expect(call, kind, message):
    e = raised(call)
    assert type(e) is kind, repr(e)
    assert str(e) == message, str(e)
    return e


def hexed(text):
    return text.encode("utf-8").hex()


def check_names():
    # The grammar's edges: one byte and 128 bytes, and every allowed character.
    assert AwsProfile("a", profile="p").name == "a"
    assert AwsProfile("x" * 128, profile="p").name == "x" * 128
    assert AwsProfile("AZaz09_.-", profile="p").name == "AZaz09_.-"
    # Outside it: empty, 129 bytes, a space, a slash, a newline at the end,
    # and a letter that is not ASCII. The message never quotes the name.
    for name in ("", "x" * 129, "raw etl", "a/b", "raw\n", "café", "s3cr3t+key="):
        expect(lambda: AwsProfile(name, profile="p"), ValueError, NAME_GRAMMAR)
    # The built-in names, in any case.
    for name in ("ambient", "anonymous", "AMBIENT", "Anonymous"):
        expect(lambda: AwsProfile(name, profile="p"), ValueError, RESERVED)
    # Not a str.
    expect(lambda: AwsProfile(b"raw", profile="p"), TypeError, "a credential name must be a str, not bytes")
    expect(lambda: AwsProfile(None, profile="p"), TypeError, "a credential name must be a str, not NoneType")


def check_values():
    # Each refusal names the setting and never the value.
    expect(lambda: AwsKeys("k", key_id="id", secret=b"s"), TypeError, "secret= must be a str, not bytes")
    expect(lambda: AwsKeys("k", key_id=1, secret="s"), TypeError, "key_id= must be a str, not int")
    expect(lambda: AwsKeys("k", key_id="id", secret=""), ValueError, "secret= is empty")
    # An optional field: None leaves it unset; empty is refused like any other.
    expect(lambda: AwsKeys("k", key_id="id", secret="s", session_token=""), ValueError, "session_token= is empty")
    # A required field cannot be left out.
    e = raised(lambda: AwsKeys("k", key_id="id"))
    assert type(e) is TypeError and "secret" in str(e), repr(e)
    # The bound is 4096 bytes of UTF-8, not 4096 characters: 2048 two-byte
    # characters fit, and one more byte does not.
    assert AwsKeys("k", key_id="id", secret="x" * 4096).name == "k"
    assert AwsKeys("k", key_id="id", secret="é" * 2048).name == "k"
    too_long = "secret= is longer than 4096 bytes of UTF-8"
    expect(lambda: AwsKeys("k", key_id="id", secret="x" * 4097), ValueError, too_long)
    expect(lambda: AwsKeys("k", key_id="id", secret="é" * 2048 + "x"), ValueError, too_long)
    # A lone surrogate has no UTF-8.
    expect(lambda: AwsKeys("k", key_id="id", secret="a\ud800"), ValueError, "secret= is not valid UTF-8")
    # Every kind checks its own fields the same way.
    expect(lambda: AwsProfile("k", profile=""), ValueError, "profile= is empty")
    expect(lambda: GcpToken("k", token=""), ValueError, "token= is empty")
    expect(lambda: AzureKey("k", account="a", key=""), ValueError, "key= is empty")
    expect(lambda: AzureSas("k", account="", sas="s"), ValueError, "account= is empty")
    expect(lambda: BearerToken("k", token=3), TypeError, "token= must be a str, not int")
    expect(lambda: OAuth2ClientCredentials("k", client_id="i", client_secret="s", scope=""), ValueError, "scope= is empty")
    expect(
        lambda: OAuth2ClientCredentials("k", client_id="i", client_secret="s", token_url=""),
        ValueError,
        "token_url= is empty",
    )
    expect(lambda: GcpServiceAccount("k", file=""), ValueError, "file= is empty")
    expect(lambda: GcpServiceAccount("k", file=b"f.json"), TypeError, "file= must be a str or os.PathLike[str], not bytes")


def check_repr_and_copies():
    # Each secret field is `<set>`; settings that are not secret are shown;
    # an unset optional field is not listed. Exact equality: no value leaks.
    assert repr(AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="hunter2")) == (
        "AwsKeys('raw-etl', key_id=<set>, secret=<set>)"
    )
    assert repr(AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="hunter2", session_token="tok")) == (
        "AwsKeys('raw-etl', key_id=<set>, secret=<set>, session_token=<set>)"
    )
    assert repr(AwsProfile("dev", profile="analytics")) == "AwsProfile('dev', profile='analytics')"
    assert repr(GcpServiceAccount("sa", file="/keys/sa.json")) == "GcpServiceAccount('sa', file='/keys/sa.json')"
    assert repr(GcpToken("g", token="ya29.secret")) == "GcpToken('g', token=<set>)"
    assert repr(AzureKey("az", account="acct", key="k3y")) == "AzureKey('az', account='acct', key=<set>)"
    assert repr(AzureSas("az", account="acct", sas="sv=1&sig=x")) == "AzureSas('az', account='acct', sas=<set>)"
    assert repr(BearerToken("b", token="t0k")) == "BearerToken('b', token=<set>)"
    assert repr(OAuth2ClientCredentials("c", client_id="etl", client_secret="cs")) == (
        "OAuth2ClientCredentials('c', client_id=<set>, client_secret=<set>, scope='catalog')"
    )
    assert repr(
        OAuth2ClientCredentials("c", client_id="etl", client_secret="cs", scope="s", token_url="https://t.example/x")
    ) == ("OAuth2ClientCredentials('c', client_id=<set>, client_secret=<set>, scope='s', token_url='https://t.example/x')")
    assert str(GcpToken("g", token="ya29.secret")) == "GcpToken('g', token=<set>)"

    # No pickle, at any protocol, and no copy.
    keys = AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="hunter2")
    for protocol in range(pickle.HIGHEST_PROTOCOL + 1):
        expect(lambda: pickle.dumps(keys, protocol=protocol), TypeError, NOT_COPIED)
    expect(lambda: copy.copy(keys), TypeError, NOT_COPIED)
    expect(lambda: copy.deepcopy(keys), TypeError, NOT_COPIED)
    expect(lambda: copy.deepcopy([keys]), TypeError, NOT_COPIED)

    # Identity, never the values: two credentials of the same values are two
    # objects, and the hash is the object's.
    twin = AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="hunter2")
    assert keys != twin and keys == keys
    assert hash(keys) == object.__hash__(keys)
    for cls in AwsKeys.__mro__[:-1]:
        assert "__hash__" not in vars(cls) and "__eq__" not in vars(cls), cls
    # The name reads back; nothing can be set on a credential.
    assert keys.name == "raw-etl"
    for attribute in ("name", "secret", "_KIND_extra"):
        e = raised(lambda: setattr(keys, attribute, "other"))
        assert type(e) is AttributeError, repr(e)
    assert keys.name == "raw-etl"

    # The built-in two: their names, their repr, copies that are themselves
    # and a pickle that names the constant.
    assert AMBIENT.name == "ambient" and ANONYMOUS.name == "anonymous"
    assert repr(AMBIENT) == "komira.AMBIENT" and repr(ANONYMOUS) == "komira.ANONYMOUS"
    for builtin in (AMBIENT, ANONYMOUS):
        assert copy.copy(builtin) is builtin and copy.deepcopy(builtin) is builtin
        for protocol in range(pickle.HIGHEST_PROTOCOL + 1):
            assert pickle.loads(pickle.dumps(builtin, protocol=protocol)) is builtin


def check_file_paths(work):
    # A relative path is resolved against the working directory and `~` is
    # expanded when the credential is built; a PathLike is taken. Nothing is
    # read: no file exists at any of these paths. The working directory and
    # HOME are put back afterwards: the runner writes its result to a path
    # relative to where the action started.
    cwd, home = os.getcwd(), os.environ.get("HOME")
    try:
        os.chdir(work)
        assert repr(GcpServiceAccount("sa", file="keys/sa.json")) == "GcpServiceAccount('sa', file={!r})".format(
            os.path.join(work, "keys", "sa.json")
        )
        os.environ["HOME"] = os.path.join(work, "home")
        assert repr(GcpServiceAccount("sa", file="~/sa.json")) == "GcpServiceAccount('sa', file={!r})".format(
            os.path.join(work, "home", "sa.json")
        )
        assert repr(GcpServiceAccount("sa", file=pathlib.Path("/abs/sa.json"))) == (
            "GcpServiceAccount('sa', file='/abs/sa.json')"
        )
    finally:
        os.chdir(cwd)
        if home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = home


class Store:
    """The fake store's lines, read with the two-call protocol."""

    def __init__(self, path):
        fn = ctypes.CDLL(path, mode=ctypes.RTLD_LOCAL).komira_fake_store
        fn.restype = ctypes.c_int32
        fn.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
        self._fn = fn

    def take(self):
        status, data = _native._two_call("komira_fake_store", self._fn)
        assert status == _native.KOMIRA_OK, status
        return data.decode("ascii").splitlines()


def check_seal(s, store):
    assert store.take() == []

    # Each kind: add with its KOMIRA_CRED_* kind and name, one set per field in
    # the order of the kind's keywords with the exact UTF-8 bytes, then seal
    # in the session scope (1). Ids count up from 1.
    s._seal_credential(AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret="wJal/rXUé"))
    assert store.take() == [
        "add 1 raw-etl 1",
        "set 1 1 " + hexed("AKIDEXAMPLE"),
        "set 1 2 " + hexed("wJal/rXUé"),
        "seal 1 1",
    ]
    s._seal_credential(AwsKeys("tmp", key_id="ASIA", secret="s", session_token="FwoG\0tail"))
    assert store.take() == [
        "add 1 tmp 2",
        "set 2 1 " + hexed("ASIA"),
        "set 2 2 " + hexed("s"),
        "set 2 3 46776f47007461696c",
        "seal 2 1",
    ]
    s._seal_credential(AwsProfile("dev", profile="analytics"))
    assert store.take() == ["add 2 dev 3", "set 3 4 " + hexed("analytics"), "seal 3 1"]
    s._seal_credential(GcpServiceAccount("sa", file="/keys/sa.json"))
    assert store.take() == ["add 3 sa 4", "set 4 5 " + hexed("/keys/sa.json"), "seal 4 1"]
    s._seal_credential(GcpToken("g", token="ya29.a0"))
    assert store.take() == ["add 4 g 5", "set 5 6 " + hexed("ya29.a0"), "seal 5 1"]
    s._seal_credential(AzureKey("az-key", account="acct", key="k3y=="))
    assert store.take() == ["add 5 az-key 6", "set 6 7 " + hexed("acct"), "set 6 8 " + hexed("k3y=="), "seal 6 1"]
    s._seal_credential(AzureSas("az-sas", account="acct", sas="sv=2024&sig=abc"))
    assert store.take() == [
        "add 6 az-sas 7",
        "set 7 7 " + hexed("acct"),
        "set 7 9 " + hexed("sv=2024&sig=abc"),
        "seal 7 1",
    ]
    s._seal_credential(BearerToken("cat", token="t0k"))
    assert store.take() == ["add 7 cat 8", "set 8 6 " + hexed("t0k"), "seal 8 1"]
    # The default scope is sent; an unset token_url is not.
    s._seal_credential(OAuth2ClientCredentials("oauth", client_id="etl", client_secret="cs"))
    assert store.take() == [
        "add 8 oauth 9",
        "set 9 10 " + hexed("etl"),
        "set 9 11 " + hexed("cs"),
        "set 9 12 " + hexed("catalog"),
        "seal 9 1",
    ]
    s._seal_credential(
        OAuth2ClientCredentials("oauth", client_id="etl", client_secret="cs", scope="read", token_url="https://t/x")
    )
    assert store.take() == [
        "add 8 oauth 10",
        "set 10 10 " + hexed("etl"),
        "set 10 11 " + hexed("cs"),
        "set 10 12 " + hexed("read"),
        "set 10 13 " + hexed("https://t/x"),
        "seal 10 1",
    ]
    # The longest value, 4096 bytes of two-byte characters, goes whole.
    s._seal_credential(GcpToken("long", token="é" * 2048))
    assert store.take() == ["add 4 long 11", "set 11 6 " + "c3a9" * 2048, "seal 11 1"]

    # The built-in two need no definition: nothing is called.
    assert s._seal_credential(AMBIENT) is None
    assert s._seal_credential(ANONYMOUS) is None
    assert store.take() == []

    # Anything else is refused before the library is called.
    expect(lambda: s._seal_credential("raw-etl"), TypeError, "credential must be a komira credential, not str")
    expect(lambda: s._seal_credential(None), TypeError, "credential must be a komira credential, not NoneType")
    assert store.take() == []


def check_refusals(s, store):
    # An engine refusal of each call is a CredentialsError, a KomiraError,
    # with the library's message unchanged and status -3; the calls after the
    # refused one are not made.
    e = expect(
        lambda: s._seal_credential(AwsKeys("refuse_add", key_id="i", secret="s")),
        CredentialsError,
        "CREDENTIALS_INVALID: add: the stand-in refuses kind 1",
    )
    assert isinstance(e, KomiraError) and e.status == -3
    assert store.take() == []

    e = expect(
        lambda: s._seal_credential(AwsKeys("bad-value", key_id="i", secret="refuse", session_token="t")),
        CredentialsError,
        "CREDENTIALS_INVALID: set credential=bad-value: the stand-in refuses field 2",
    )
    assert e.status == -3
    assert store.take() == ["add 1 bad-value 12", "set 12 1 69"]

    e = expect(
        lambda: s._seal_credential(BearerToken("refuse_seal", token="t")),
        CredentialsError,
        "CREDENTIALS_INVALID: seal credential=refuse_seal: the stand-in refuses it",
    )
    assert e.status == -3
    assert store.take() == ["add 7 refuse_seal 13", "set 13 6 74"]

    # Not an engine refusal: a NULL-argument status is a plain KomiraError
    # with its message, and a -3 with no last error is a plain KomiraError
    # naming the call, since there is no named refusal to report.
    e = expect(lambda: s._seal_credential(GcpToken("null_arg", token="t")), KomiraError, "out_id is NULL")
    assert e.status == -2
    e = expect(
        lambda: s._seal_credential(GcpToken("silent", token="t")),
        KomiraError,
        "komira_credential_add failed with status -3 and no message",
    )
    assert e.status == -3
    assert store.take() == []

    # The session still works after each refusal.
    s._seal_credential(GcpToken("after", token="t"))
    assert store.take() == ["add 4 after 14", "set 14 6 74", "seal 14 1"]


def check_native(native, ctx, store):
    # The Native calls check their own arguments before the library is called.
    expect(lambda: native.credential_set(ctx, 1, 2, "text"), TypeError, "value must be bytes, not str")
    expect(lambda: native.credential_add(ctx, 1, "a\0b"), ValueError, "name holds a NUL byte")
    expect(lambda: native.credential_add(ctx, 1, b"a"), TypeError, "name must be a str, not bytes")
    assert store.take() == []
    # A value is bytes with a length: a NUL inside it is sent, and the scope
    # is the caller's.
    cred_id = native.credential_add(ctx, 3, "n")
    native.credential_set(ctx, cred_id, 5, b"a\0b")
    native.credential_seal(ctx, cred_id, 7)
    assert store.take() == ["add 3 n {}".format(cred_id), "set {} 5 610062".format(cred_id), "seal {} 7".format(cred_id)]


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])

    # Building credentials loads nothing.
    check_names()
    check_values()
    check_repr_and_copies()
    check_file_paths(lib_dir)
    assert _native._loaded is None

    native = _native.load(os.path.join(lib_dir, "fake_store"))
    assert komira.abi_version() == 1002
    store = Store(native.path)
    with komira.Session() as s:
        check_seal(s, store)
        check_refusals(s, store)
        check_native(native, s._ctx, store)

    # A closed session refuses every credential, the built-in two included,
    # and calls nothing.
    for credential in (GcpToken("late", token="t"), AMBIENT, ANONYMOUS):
        expect(lambda: s._seal_credential(credential), KomiraError, "the session is closed")
    assert store.take() == []
    print("credentials: objects, and sealing on the fake store of libkomira {}".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
