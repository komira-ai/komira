"""File sources: `files(location, ...)`, what `Session.add_sql_binding` binds
(docs/design/credentials_and_writes.md, decision 1).

A source says where data is and who reads it. Building one does no I/O and
calls no library; `Session.add_sql_binding` seals its credential on the
session and binds a SQL name to it through `komira_add_sql_binding`, with the
source as the bytes of a `komira.plan.v1.WireBoundSource`
(src/plan_proto/bound_source.proto). Those bytes carry the credential's NAME
and the store's settings, never a value: a secret leaves Python only through
`komira_credential_set`'s byte buffer, when the session seals it.

`location` is a local path, a glob, or a URL. A string that starts with a
scheme (`<letters>://`) is a URL and is kept as written; anything else is a
local path, with `~` expanded and made absolute against the working directory
now, as `Session.register_parquet` does. `credential=`, `endpoint=`,
`region=` and `url_style=` say how to reach an object store; the names are
DuckDB's S3 settings (`ENDPOINT`, `REGION`, `URL_STYLE`).

Arguments are checked when the source is built, before any library call: a
wrong type raises `TypeError` and a wrong value `ValueError`. A credential of
another store than the location's (an `AzureKey` on `s3://`), and any setting
on a local path, are a `ValueError`; the library refuses them again by name.
What the library does not read yet (a `gs://` location, `ANONYMOUS` or an
`AwsProfile` on `s3://`, `AMBIENT` on any store) is refused by the library
when the source is bound, with its named code.

A source holds a credential, so like one it refuses `pickle` and `copy` with
`TypeError`, compares by identity, and shows each secret as `<set>` in its
`repr()`.
"""

from __future__ import annotations

import os
import re
from typing import NoReturn

from ._credentials import (
    AMBIENT,
    ANONYMOUS,
    AwsKeys,
    AwsProfile,
    AzureKey,
    AzureSas,
    GcpServiceAccount,
    GcpToken,
    _BuiltIn,
    _Credential,
)
from ._iceberg import _kind

# A URL: a scheme, then `://` (RFC 3986's scheme grammar).
_URL = re.compile(r"([A-Za-z][A-Za-z0-9+.\-]*)://")

# `url_style=`: DuckDB's URL_STYLE values, and the `AddressingStyleWire`
# number each is on the wire.
URL_STYLES = {"vhost": 1, "path": 2}

# The credentials each store's schemes take, beside AMBIENT and ANONYMOUS
# (decision 1: a credential must fit its source). A scheme not listed here is
# checked by the library alone.
_FITS: dict[str, tuple[type[_Credential], ...]] = {
    **dict.fromkeys(("s3", "s3a"), (AwsKeys, AwsProfile)),
    **dict.fromkeys(("gs", "gcs"), (GcpServiceAccount, GcpToken)),
    **dict.fromkeys(("az", "abfs", "abfss"), (AzureKey, AzureSas)),
}

_NOT_COPIED = "a komira source cannot be pickled or copied: it holds a credential"


def _utf8(what: str, value: str) -> str:
    """`value`, refused with ValueError when it is not valid UTF-8 (a lone
    surrogate) or holds a NUL byte; the message never quotes it."""
    if "\0" in value:
        raise ValueError("{} holds a NUL byte".format(what))
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("{} is not valid UTF-8".format(what)) from None
    return value


def _setting(what: str, value: object) -> str | None:
    """An optional text setting: None, or a non-empty `str` of UTF-8."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError("{}= must be a str or None, not {}".format(what, type(value).__name__))
    if not value:
        raise ValueError("{}= is empty".format(what))
    return _utf8(what + "=", value)


def _location(location: object) -> tuple[str, str | None]:
    """The location as the library is given it, and its scheme in lower
    case, or None for a local path."""
    if isinstance(location, os.PathLike):
        location = os.fspath(location)
    if not isinstance(location, str):
        raise TypeError("location must be a str or os.PathLike[str], not {}".format(type(location).__name__))
    if not location:
        raise ValueError("location is empty")
    _utf8("location", location)
    url = _URL.match(location)
    if url is not None:
        return location, url.group(1).lower()
    return os.path.abspath(os.path.expanduser(location)), None


class _FileSource:
    """Data files at a location, how to reach their store, and the credential
    that reads them: what `files` builds."""

    __slots__ = ("_location", "_scheme", "_credential", "_endpoint", "_region", "_url_style")

    def __init__(
        self,
        location: str,
        scheme: str | None,
        credential: _Credential | _BuiltIn,
        endpoint: str | None,
        region: str | None,
        url_style: str | None,
    ) -> None:
        self._location = location
        self._scheme = scheme
        self._credential = credential
        self._endpoint = endpoint
        self._region = region
        self._url_style = url_style

    def _wire(self) -> bytes:
        """The `WireBoundSource` bytes of this source: its `files` arm, with
        the location and the access (the credential's name and the store's
        settings). No secret is in them."""
        access = _text(1, self._credential.name)
        if self._endpoint is not None:
            access += _text(2, self._endpoint)
        if self._region is not None:
            access += _text(3, self._region)
        if self._url_style is not None:
            access += _varint(4 << 3) + _varint(URL_STYLES[self._url_style])
        files = _text(1, self._location) + _message(2, access)
        return _message(1, files)

    def __repr__(self) -> str:
        shown = [repr(self._location), "credential={!r}".format(self._credential)]
        for setting, value in (("endpoint", self._endpoint), ("region", self._region), ("url_style", self._url_style)):
            if value is not None:
                shown.append("{}={!r}".format(setting, value))
        return "komira.files({})".format(", ".join(shown))

    def __reduce_ex__(self, protocol: object) -> NoReturn:
        raise TypeError(_NOT_COPIED)

    def __copy__(self) -> NoReturn:
        raise TypeError(_NOT_COPIED)

    def __deepcopy__(self, memo: object) -> NoReturn:
        raise TypeError(_NOT_COPIED)


def files(
    location: str | os.PathLike[str],
    *,
    credential: _Credential | _BuiltIn = AMBIENT,
    endpoint: str | None = None,
    region: str | None = None,
    url_style: str | None = None,
) -> _FileSource:
    """Parquet files at `location`, a source `Session.add_sql_binding` binds
    to a SQL name.

    `location` is a local path or glob, or a URL of an object store:
    `s3://bucket/key` (`s3a://` too), or `az://container/blob` (`abfs://`,
    `abfss://`). The key may be a glob (`*`, `?`, `[...]`, `{a,b}`, one
    `**`), listed when the source is bound. `credential` reads it:
    `AwsKeys` (or `AwsProfile`) for `s3://`, `GcpServiceAccount` or `GcpToken`
    for `gs://`, `AzureKey` or `AzureSas` for Azure, `ANONYMOUS` for an
    unsigned read, and `AMBIENT`, the default, for the process's own
    identity. `endpoint` is the store's address when it is not the
    provider's (`http://` reaches an emulator in plaintext), `region` the
    S3 region requests are signed for, and `url_style` `"vhost"` (the bucket
    in the host name) or `"path"` (the bucket as the first path segment);
    None leaves each to the store, which addresses its own endpoint by path.

    A local path is read under the process's identity and takes no
    credential but `AMBIENT` and no setting. Raises `TypeError` for an
    argument of the wrong type and `ValueError` for an empty location or
    setting, a `url_style` other than the two, a credential of another store,
    and a setting on a local path. No message quotes a credential's value.
    """
    where, scheme = _location(location)
    if not isinstance(credential, (_Credential, _BuiltIn)):
        raise TypeError("credential= must be a komira credential, not {}".format(type(credential).__name__))
    endpoint = _setting("endpoint", endpoint)
    region = _setting("region", region)
    url_style = _setting("url_style", url_style)
    if url_style is not None and url_style not in URL_STYLES:
        raise ValueError("url_style= must be 'vhost' or 'path', not {!r}".format(url_style))
    if scheme is None:
        if credential is not AMBIENT:
            raise ValueError(
                "a local path is read under the process's own identity: credential= takes only komira.AMBIENT,"
                " not {}".format(_kind(credential))
            )
        if endpoint is not None or region is not None or url_style is not None:
            raise ValueError("a local path takes no endpoint=, region= or url_style=")
    elif scheme in _FITS and credential not in (AMBIENT, ANONYMOUS) and not isinstance(credential, _FITS[scheme]):
        raise ValueError("credential= is {}, which does not read {}:// locations".format(_kind(credential), scheme))
    return _FileSource(where, scheme, credential, endpoint, region, url_style)


# ---- The protobuf wire (proto3), for the three field kinds the message uses


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        low = n & 0x7F
        n >>= 7
        if n:
            out.append(low | 0x80)
        else:
            out.append(low)
            return bytes(out)


def _message(field: int, body: bytes) -> bytes:
    """A length-delimited field: an embedded message, or UTF-8 text."""
    return _varint(field << 3 | 2) + _varint(len(body)) + body


def _text(field: int, value: str) -> bytes:
    """A string field; `files` checked that the value is UTF-8."""
    return _message(field, value.encode("utf-8"))
