"""Credentials on the real libkomira (ABI 1.2): every kind the package builds
seals on a session, the boundaries the package accepts are accepted by the
library, and every refusal of the library's credential calls is raised as a
`CredentialsError` carrying the library's named message,
`CREDENTIALS_INVALID: ...`, unchanged and never quoting a value.

    test_credentials_lib.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import os
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

AWS_KEYS = 1
FIELD_KEY_ID, FIELD_SECRET, FIELD_TOKEN = 1, 2, 6
SECRET = "wJalrXUtnFEMI/K7MDENG"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, message):
    """`call` raises a CredentialsError with the library's message `message`
    and status -3, and the message holds no secret this test passes."""
    e = raised(call)
    assert type(e) is CredentialsError, repr(e)
    assert isinstance(e, KomiraError)
    assert str(e) == message, str(e)
    assert e.status == -3, e.status
    assert SECRET not in str(e)


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    native = _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1002, komira.abi_version()

    with komira.Session() as s:
        # Every kind, with every field it takes, seals; so does sealing the
        # same name again, with the same value or another, and the built-in
        # two, which call nothing.
        for credential in (
            AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret=SECRET),
            AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret=SECRET),
            AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret=SECRET + "2", session_token="FwoGZXIvYXdzEJr"),
            AwsProfile("dev", profile="analytics"),
            GcpServiceAccount("sa", file="/keys/sa.json"),
            GcpToken("g", token="ya29.a0"),
            AzureKey("az-key", account="acct", key="k3y=="),
            AzureSas("az-sas", account="acct", sas="sv=2024&sig=abc"),
            BearerToken("cat", token="t0k"),
            OAuth2ClientCredentials("oauth", client_id="etl", client_secret="cs"),
            OAuth2ClientCredentials(
                "oauth2", client_id="etl", client_secret="cs", scope="read", token_url="https://token.example/x"
            ),
            AMBIENT,
            ANONYMOUS,
        ):
            assert s._seal_credential(credential) is None, credential

        # The package's edges are the library's: a 128-byte name, and a value
        # of 4096 bytes of UTF-8 in 2048 two-byte characters.
        assert s._seal_credential(GcpToken("n" * 128, token="é" * 2048)) is None
        assert s._seal_credential(AwsKeys("Az09_.-", key_id="k", secret="é" * 2048)) is None

        # What the package refuses before the library is called, the library
        # refuses too, by name: through the Native calls directly.
        ctx = s._ctx
        refused(
            lambda: native.credential_add(ctx, AWS_KEYS, "n" * 129),
            "CREDENTIALS_INVALID: add credential: the name is not 1 to 128 bytes of letters, digits, '_', '.' and '-'",
        )
        refused(
            lambda: native.credential_add(ctx, AWS_KEYS, "Ambient"),
            "CREDENTIALS_INVALID: add credential: ambient and anonymous are built in and are not defined",
        )
        refused(
            lambda: native.credential_add(ctx, 99, "k"),
            "CREDENTIALS_INVALID: add credential: kind 99 is not a KOMIRA_CRED_* kind",
        )

        def opened(name):
            return native.credential_add(ctx, AWS_KEYS, name)

        refused(
            lambda: native.credential_set(ctx, opened("k"), FIELD_SECRET, b""),
            "CREDENTIALS_INVALID: set credential=k: secret= is empty",
        )
        refused(
            lambda: native.credential_set(ctx, opened("k"), FIELD_SECRET, b"x" * 4097),
            "CREDENTIALS_INVALID: set credential=k: secret= is longer than 4096 bytes",
        )
        refused(
            lambda: native.credential_set(ctx, opened("k"), FIELD_SECRET, b"ok\xff"),
            "CREDENTIALS_INVALID: set credential=k: secret= is not UTF-8",
        )
        refused(
            lambda: native.credential_set(ctx, opened("k"), FIELD_TOKEN, b"t"),
            "CREDENTIALS_INVALID: set credential=k: AwsKeys has no token=",
        )

        # A definition missing a field its kind needs is refused at seal, and
        # discarded: sealing it again names it as not open.
        cred_id = opened("half")
        native.credential_set(ctx, cred_id, FIELD_KEY_ID, b"AKIDEXAMPLE")
        refused(
            lambda: native.credential_seal(ctx, cred_id),
            "CREDENTIALS_INVALID: seal credential=half: AwsKeys needs secret=",
        )
        refused(
            lambda: native.credential_seal(ctx, cred_id),
            "CREDENTIALS_INVALID: seal credential: id {} is not an open definition".format(cred_id),
        )
        # A refused set discards its definition too.
        cred_id = opened("k")
        refused(
            lambda: native.credential_set(ctx, cred_id, FIELD_SECRET, b""),
            "CREDENTIALS_INVALID: set credential=k: secret= is empty",
        )
        refused(
            lambda: native.credential_set(ctx, cred_id, FIELD_SECRET, SECRET.encode()),
            "CREDENTIALS_INVALID: set credential: id {} is not an open definition".format(cred_id),
        )
        # A scope other than the session's is refused.
        cred_id = opened("scoped")
        native.credential_set(ctx, cred_id, FIELD_KEY_ID, b"AKIDEXAMPLE")
        native.credential_set(ctx, cred_id, FIELD_SECRET, SECRET.encode())
        refused(
            lambda: native.credential_seal(ctx, cred_id, 2),
            "CREDENTIALS_INVALID: seal credential=scoped: scope 2 is not KOMIRA_BIND_SESSION",
        )

        # A failure that is not the engine's refusal is a plain KomiraError: a
        # value above KOMIRA_MAX_INPUT_BYTES is -5, before it is read.
        cred_id = opened("big")
        e = raised(lambda: native.credential_set(ctx, cred_id, FIELD_SECRET, b"x" * (64 * 1024 * 1024 + 1)))
        assert type(e) is KomiraError and e.status == -5, repr(e)
        assert str(e) == "komira_credential_set: value_len is above 67108864 bytes", str(e)

        # After every refusal the session still seals, and the last error was
        # cleared by the call that succeeded.
        assert s._seal_credential(AwsKeys("raw-etl", key_id="AKIDEXAMPLE", secret=SECRET)) is None
        assert native.last_error(ctx) == ""

    print("credentials: libkomira {} seals every kind and names its refusals".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
