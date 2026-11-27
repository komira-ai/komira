"""Credentials: who reads a source (docs/design/credentials_and_writes.md, decision 1).

A credential is a value the user builds and holds; building one does no I/O
and calls no library. Every credential has a name, which is what a plan
carries; its fields are what `Session._seal_credential` copies into the
session's secret store through `komira_credential_add`, `_set` and `_seal`
(src/so/README.md, Credentials). `komira.files` takes one as its
`credential=`, and `Session.add_sql_binding` seals it when it binds the
source. The package exports the kinds a file source takes (`AwsKeys`,
`AwsProfile`, `GcpServiceAccount`, `GcpToken`, `AzureKey`, `AzureSas`,
`AMBIENT` and `ANONYMOUS`); `BearerToken` and `OAuth2ClientCredentials`,
which only a catalog takes, stay private until a catalog can be bound.

Arguments are checked when the credential is built, before any library call:
a name, a field or a value of the wrong type raises `TypeError`, and a name
outside the grammar, a reserved name, or an empty, oversized or non-UTF-8
value raises `ValueError`. No message quotes a name it refuses or any value,
since either may be a pasted secret.

What a credential will not do: `repr()` shows its kind, its name and the
settings that are not secret, and each secret field as `<set>`; it refuses
`pickle` and `copy` with `TypeError`; it defines no `__hash__` or `__eq__`
of its own, so it hashes and compares by identity and never by its values.
A secret is a Python `str` until the library copies it; the package cannot
wipe interpreter memory and does not claim to.
"""

from __future__ import annotations

import os
import re
from typing import NoReturn

# The kinds and the fields of ABI 1.2 (src/so/abi/komira.tsv).
KOMIRA_CRED_AWS_KEYS = 1
KOMIRA_CRED_AWS_PROFILE = 2
KOMIRA_CRED_GCP_SERVICE_ACCOUNT = 3
KOMIRA_CRED_GCP_TOKEN = 4
KOMIRA_CRED_AZURE_KEY = 5
KOMIRA_CRED_AZURE_SAS = 6
KOMIRA_CRED_BEARER = 7
KOMIRA_CRED_OAUTH2_CLIENT = 8

KOMIRA_FIELD_KEY_ID = 1
KOMIRA_FIELD_SECRET = 2
KOMIRA_FIELD_SESSION_TOKEN = 3
KOMIRA_FIELD_PROFILE = 4
KOMIRA_FIELD_FILE = 5
KOMIRA_FIELD_TOKEN = 6
KOMIRA_FIELD_ACCOUNT = 7
KOMIRA_FIELD_KEY = 8
KOMIRA_FIELD_SAS = 9
KOMIRA_FIELD_CLIENT_ID = 10
KOMIRA_FIELD_CLIENT_SECRET = 11
KOMIRA_FIELD_SCOPE = 12
KOMIRA_FIELD_TOKEN_URL = 13

# The longest value a field takes, in UTF-8 bytes: the library's
# `SecretValue` bound.
MAX_VALUE_BYTES = 4096

# A name: 1 to 128 ASCII letters, digits, `_`, `.` and `-`.
_NAME = re.compile(r"[A-Za-z0-9_.\-]{1,128}")

# The fields a kind may leave unset: None for one of these is "not set"; for
# every other field it is a value of the wrong type.
_OPTIONAL = ("session_token", "token_url")

# The built-in names, in any case: `AMBIENT` and `ANONYMOUS` are their only
# spellings.
_RESERVED = ("ambient", "anonymous")


def _check_name(name: object) -> str:
    if not isinstance(name, str):
        raise TypeError("a credential name must be a str, not {}".format(type(name).__name__))
    if _NAME.fullmatch(name) is None:
        raise ValueError("a credential name must be 1 to 128 ASCII letters, digits, '_', '.' or '-'")
    if name.lower() in _RESERVED:
        raise ValueError(
            "the credential names ambient and anonymous are reserved: use komira.AMBIENT or komira.ANONYMOUS"
        )
    return name


def _check_value(setting: str, value: object) -> str:
    """`value` of the field the keyword `setting` sets, checked as the library
    checks it: a non-empty str of at most MAX_VALUE_BYTES bytes of UTF-8."""
    if not isinstance(value, str):
        raise TypeError("{}= must be a str, not {}".format(setting, type(value).__name__))
    if not value:
        raise ValueError("{}= is empty".format(setting))
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError:
        raise ValueError("{}= is not valid UTF-8".format(setting)) from None
    if size > MAX_VALUE_BYTES:
        raise ValueError("{}= is longer than {} bytes of UTF-8".format(setting, MAX_VALUE_BYTES))
    return value


class _Credential:
    """What every defined credential is: a kind, a name, and its fields in
    the order they are set, each with whether it is a secret."""

    __slots__ = ("_name", "_fields")

    # The kind's `KOMIRA_CRED_*`, set by each subclass.
    _KIND: int

    def __init__(self, name: object, fields: list[tuple[str, int, object, bool]]) -> None:
        """`fields` holds (keyword, `KOMIRA_FIELD_*`, value, secret) for each
        field of the kind; None for an optional field leaves it unset, and
        for any other field is refused with `TypeError`."""
        self._name = _check_name(name)
        self._fields = tuple(
            (setting, field, _check_value(setting, value), secret)
            for setting, field, value, secret in fields
            if value is not None or setting not in _OPTIONAL
        )

    @property
    def name(self) -> str:
        """The name the plan carries."""
        return self._name

    def _definition(self) -> tuple[int, str, tuple[tuple[int, str], ...]]:
        """What the library is given: the kind, the name, and each set field
        with its value."""
        return self._KIND, self._name, tuple((field, value) for _, field, value, _ in self._fields)

    def __repr__(self) -> str:
        shown = ", ".join(
            "{}={}".format(setting, "<set>" if secret else repr(value)) for setting, _, value, secret in self._fields
        )
        return "{}({!r}, {})".format(type(self).__name__, self._name, shown)

    def __reduce_ex__(self, protocol: object) -> NoReturn:
        raise TypeError("a komira credential cannot be pickled or copied: it holds a secret")

    def __copy__(self) -> NoReturn:
        self.__reduce_ex__(None)

    def __deepcopy__(self, memo: object) -> NoReturn:
        self.__reduce_ex__(None)


class AwsKeys(_Credential):
    """Static AWS keys: `key_id` and `secret`, and a `session_token` for
    temporary keys."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_AWS_KEYS

    def __init__(self, name: str, *, key_id: str, secret: str, session_token: str | None = None) -> None:
        super().__init__(
            name,
            [
                ("key_id", KOMIRA_FIELD_KEY_ID, key_id, True),
                ("secret", KOMIRA_FIELD_SECRET, secret, True),
                ("session_token", KOMIRA_FIELD_SESSION_TOKEN, session_token, True),
            ],
        )


class AwsProfile(_Credential):
    """A profile of the shared AWS files, found through `AWS_CONFIG_FILE`,
    `AWS_SHARED_CREDENTIALS_FILE` and `HOME` when it is first read, never
    through `AWS_PROFILE`."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_AWS_PROFILE

    def __init__(self, name: str, *, profile: str) -> None:
        super().__init__(name, [("profile", KOMIRA_FIELD_PROFILE, profile, False)])


class GcpServiceAccount(_Credential):
    """A Google credentials file of the kind `GOOGLE_APPLICATION_CREDENTIALS`
    names. `file` is a str or `os.PathLike[str]`; `~` is expanded and a
    relative path is resolved against the working directory now, and the file
    is read when a source first needs it."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_GCP_SERVICE_ACCOUNT

    def __init__(self, name: str, *, file: str | os.PathLike[str]) -> None:
        if isinstance(file, os.PathLike):
            file = os.fspath(file)
        if not isinstance(file, str):
            raise TypeError("file= must be a str or os.PathLike[str], not {}".format(type(file).__name__))
        if file:
            file = os.path.abspath(os.path.expanduser(file))
        super().__init__(name, [("file", KOMIRA_FIELD_FILE, file, False)])


class GcpToken(_Credential):
    """A Google OAuth access token."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_GCP_TOKEN

    def __init__(self, name: str, *, token: str) -> None:
        super().__init__(name, [("token", KOMIRA_FIELD_TOKEN, token, True)])


class AzureKey(_Credential):
    """An Azure storage account and its Shared Key."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_AZURE_KEY

    def __init__(self, name: str, *, account: str, key: str) -> None:
        super().__init__(
            name,
            [("account", KOMIRA_FIELD_ACCOUNT, account, False), ("key", KOMIRA_FIELD_KEY, key, True)],
        )


class AzureSas(_Credential):
    """An Azure storage account and a shared access signature."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_AZURE_SAS

    def __init__(self, name: str, *, account: str, sas: str) -> None:
        super().__init__(
            name,
            [("account", KOMIRA_FIELD_ACCOUNT, account, False), ("sas", KOMIRA_FIELD_SAS, sas, True)],
        )


class BearerToken(_Credential):
    """A bearer token, for a catalog."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_BEARER

    def __init__(self, name: str, *, token: str) -> None:
        super().__init__(name, [("token", KOMIRA_FIELD_TOKEN, token, True)])


class OAuth2ClientCredentials(_Credential):
    """An OAuth 2 client-credentials grant, for a catalog: `client_id` and
    `client_secret`, the `scope` asked for, and the `token_url` to exchange
    them at (None: the catalog's own)."""

    __slots__ = ()
    _KIND = KOMIRA_CRED_OAUTH2_CLIENT

    def __init__(
        self,
        name: str,
        *,
        client_id: str,
        client_secret: str,
        scope: str = "catalog",
        token_url: str | None = None,
    ) -> None:
        super().__init__(
            name,
            [
                ("client_id", KOMIRA_FIELD_CLIENT_ID, client_id, True),
                ("client_secret", KOMIRA_FIELD_CLIENT_SECRET, client_secret, True),
                ("scope", KOMIRA_FIELD_SCOPE, scope, False),
                ("token_url", KOMIRA_FIELD_TOKEN_URL, token_url, False),
            ],
        )


class _BuiltIn:
    """A built-in credential: `AMBIENT` or `ANONYMOUS`. It has a name and no
    definition, so nothing is sealed for it; copying it gives itself and
    pickling it names the module constant."""

    __slots__ = ("_name", "_constant")

    def __init__(self, name: str, constant: str) -> None:
        self._name = name
        self._constant = constant

    @property
    def name(self) -> str:
        """The reserved name the plan carries."""
        return self._name

    def __repr__(self) -> str:
        return "komira.{}".format(self._constant)

    def __reduce__(self) -> str:
        return self._constant

    def __copy__(self) -> _BuiltIn:
        return self

    def __deepcopy__(self, memo: object) -> _BuiltIn:
        return self


# Whatever identity runs the plan: locally, the process's own, through the AWS
# and Google provider chains when a source naming it is first read (decision 7).
AMBIENT = _BuiltIn("ambient", "AMBIENT")

# No credential: requests are not signed.
ANONYMOUS = _BuiltIn("anonymous", "ANONYMOUS")
