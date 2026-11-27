"""Iceberg catalogs and tables as sources (docs/design/iceberg_tables.md, "What the user sees").

`iceberg(uri, ...)` builds an `IcebergCatalog`: a REST catalog of many
tables, which SQL will name as `catalog.namespace.table`. `catalog.table(name)`
builds an `IcebergTable`: one table of it, which uses the catalog's
credential. `SigV4(region, service)` is the request signing a catalog may
take. Building any of them does no I/O and calls no library: nothing is sent to
the catalog until a statement that binds it names one of its tables.

Nothing public takes one yet: the names here are private until
`Session.add_sql_binding` and `read_table` can bind them (the library binds
only file sources today), which exports them.

Arguments are checked when the value is built: a wrong type raises
`TypeError`, and a wrong value raises `ValueError`. A credential that does not
fit the catalog is a `ValueError` here; the library refuses it again at bind
with `CREDENTIAL_KIND_MISMATCH` (docs/design/credentials_and_writes.md). A
catalog or a table holds a credential, so its `repr()` shows the credential's
own, with every secret as `<set>`, and it refuses `pickle` and `copy` with
`TypeError` as a credential does. Like a credential, a catalog or a table
defines no `__eq__` or `__hash__`: two are equal only when they are the same
object. `SigV4` holds no secret and compares by its region and service.
"""

from __future__ import annotations

from typing import NoReturn
from urllib.parse import urlsplit

from ._credentials import AMBIENT, ANONYMOUS, AwsKeys, BearerToken, OAuth2ClientCredentials, _BuiltIn, _Credential

# The values of `access_delegation=`: how the catalog gives access to the
# table's files. Any other value, "remote-signing" among them, is refused.
ACCESS_DELEGATIONS = ("vended-credentials", "none")

# The schemes of a catalog URI.
_SCHEMES = ("http", "https")

_NOT_COPIED = "a komira Iceberg catalog or table cannot be pickled or copied: it holds a credential"


def _check_text(setting: str, value: object) -> str:
    """`value` of `setting`: a non-empty str with no control character."""
    if not isinstance(value, str):
        raise TypeError("{} must be a str, not {}".format(setting, type(value).__name__))
    if not value:
        raise ValueError("{} is empty".format(setting))
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        raise ValueError("{} holds a control character".format(setting))
    return value


def _check_uri(uri: object) -> str:
    """The catalog's base URI: http or https, with a host, and with no user,
    password, query or fragment. The URI is not quoted when it is refused,
    since a pasted one may hold a password."""
    uri = _check_text("uri", uri)
    try:
        parts = urlsplit(uri)
        _ = parts.port  # a port that is not a number in range raises here
    except ValueError:
        raise ValueError("uri is not a URI") from None
    if parts.scheme.lower() not in _SCHEMES:
        raise ValueError("uri must be an http or https URI")
    if not parts.hostname:
        raise ValueError("uri has no host")
    if parts.username is not None or parts.password is not None:
        raise ValueError("uri must not hold a user or a password: give the catalog a credential= instead")
    if parts.query or parts.fragment or uri.endswith(("?", "#")):
        raise ValueError("uri must not hold a query or a fragment")
    return uri


class SigV4:
    """AWS Signature Version 4 request signing, `signing=` of a catalog: every
    request to the catalog is signed for `region` and `service` with the AWS
    credential the catalog names. The service is the user's value (the
    catalog's documentation names it); komira does not pick one."""

    __slots__ = ("_region", "_service")

    def __init__(self, region: str, service: str) -> None:
        self._region = _check_text("region", region)
        self._service = _check_text("service", service)

    @property
    def region(self) -> str:
        """The region a request is signed for."""
        return self._region

    @property
    def service(self) -> str:
        """The service name a request is signed for."""
        return self._service

    def __repr__(self) -> str:
        return "SigV4({!r}, {!r})".format(self._region, self._service)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, SigV4):
            return NotImplemented
        return (self._region, self._service) == (other._region, other._service)

    def __hash__(self) -> int:
        return hash((SigV4, self._region, self._service))


def _check_credential(credential: object, signing: SigV4 | None) -> _Credential | _BuiltIn:
    """The catalog's credential, checked against its signing: with SigV4, an
    AWS credential (`AMBIENT` or `AwsKeys`); without, `AMBIENT`, `ANONYMOUS`,
    `BearerToken` or `OAuth2ClientCredentials`."""
    if not isinstance(credential, (_Credential, _BuiltIn)):
        raise TypeError("credential= must be a komira credential, not {}".format(type(credential).__name__))
    if signing is not None:
        if credential is not AMBIENT and not isinstance(credential, AwsKeys):
            raise ValueError(
                "a catalog signed with SigV4 takes komira.AMBIENT or an AwsKeys credential, not {}".format(
                    _kind(credential)
                )
            )
    elif credential is not AMBIENT and credential is not ANONYMOUS:
        if not isinstance(credential, (BearerToken, OAuth2ClientCredentials)):
            raise ValueError(
                "a catalog takes komira.AMBIENT, komira.ANONYMOUS, a BearerToken or an "
                "OAuth2ClientCredentials credential, not {}; an AwsKeys credential needs signing=SigV4(...)".format(
                    _kind(credential)
                )
            )
    return credential


def _kind(credential: _Credential | _BuiltIn) -> str:
    """The credential's kind, for a message: its class or constant, never its
    name or a value."""
    if isinstance(credential, _BuiltIn):
        return repr(credential)
    return type(credential).__name__


def _split_name(name: object) -> tuple[tuple[str, ...], str]:
    """A table name: "namespace.table", split on every '.', so "a.b.t" is the
    table t in the namespace a.b; or a tuple of namespace levels and the table
    name, for a level that holds a '.'. Every part is non-empty, and a table
    always lives in a namespace."""
    if isinstance(name, str):
        parts: tuple[object, ...] = tuple(name.split("."))
        what = "table name"
    elif isinstance(name, tuple):
        parts = name
        what = "table name tuple"
    else:
        raise TypeError("a table name must be a str or a tuple of str, not {}".format(type(name).__name__))
    for part in parts:
        if not isinstance(part, str):
            raise TypeError("each part of a {} must be a str, not {}".format(what, type(part).__name__))
        _check_part(what, part)
    if len(parts) < 2:
        raise ValueError(
            'a {} needs a namespace and a table, as "namespace.table" or ("namespace", "table")'.format(what)
        )
    return tuple(parts[:-1]), parts[-1]  # type: ignore[return-value]


def _check_part(what: str, part: str) -> None:
    if not part:
        raise ValueError("a {} has an empty part".format(what))
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in part):
        raise ValueError("a {} holds a control character".format(what))


class _HoldsCredential:
    """A catalog or a table: it holds a credential, so it is neither pickled
    nor copied."""

    __slots__ = ()

    def __reduce_ex__(self, protocol: object) -> NoReturn:
        raise TypeError(_NOT_COPIED)

    def __copy__(self) -> NoReturn:
        raise TypeError(_NOT_COPIED)

    def __deepcopy__(self, memo: object) -> NoReturn:
        raise TypeError(_NOT_COPIED)


class IcebergCatalog(_HoldsCredential):
    """An Iceberg REST catalog: where it is (`uri`, `warehouse`), who reads it
    (`credential`, `signing`) and how it gives access to the tables' files
    (`access_delegation`). Build one with `iceberg(...)`."""

    __slots__ = ("_uri", "_warehouse", "_credential", "_signing", "_access_delegation")

    def __init__(
        self,
        uri: str,
        *,
        warehouse: str | None = None,
        credential: _Credential | _BuiltIn = AMBIENT,
        signing: SigV4 | None = None,
        access_delegation: str = "vended-credentials",
    ) -> None:
        self._uri = _check_uri(uri)
        self._warehouse = None if warehouse is None else _check_text("warehouse=", warehouse)
        if signing is not None and not isinstance(signing, SigV4):
            raise TypeError("signing= must be a komira SigV4 or None, not {}".format(type(signing).__name__))
        self._signing = signing
        self._credential = _check_credential(credential, signing)
        if not isinstance(access_delegation, str):
            raise TypeError("access_delegation= must be a str, not {}".format(type(access_delegation).__name__))
        if access_delegation not in ACCESS_DELEGATIONS:
            raise ValueError(
                "access_delegation= {!r} is not supported: use 'vended-credentials' or 'none'".format(
                    access_delegation
                )
            )
        self._access_delegation = access_delegation

    @property
    def uri(self) -> str:
        """The catalog's base URI, as given."""
        return self._uri

    @property
    def warehouse(self) -> str | None:
        """The warehouse the catalog's config is asked for, or None."""
        return self._warehouse

    @property
    def credential(self) -> _Credential | _BuiltIn:
        """The credential the catalog is read with; the plan carries its name."""
        return self._credential

    @property
    def signing(self) -> SigV4 | None:
        """The request signing, or None."""
        return self._signing

    @property
    def access_delegation(self) -> str:
        """'vended-credentials' or 'none'."""
        return self._access_delegation

    def table(self, name: str | tuple[str, ...]) -> IcebergTable:
        """One table of this catalog: `name` is "namespace.table" (every '.'
        separates two parts, so "a.b.t" is the table t of the namespace a.b),
        or a tuple of namespace levels and the table name when a part holds a
        '.'. The table uses the catalog's credential. Nothing is read."""
        namespace, table = _split_name(name)
        return IcebergTable(self, namespace, table)

    def __repr__(self) -> str:
        shown = ["{!r}".format(self._uri)]
        if self._warehouse is not None:
            shown.append("warehouse={!r}".format(self._warehouse))
        shown.append("credential={!r}".format(self._credential))
        if self._signing is not None:
            shown.append("signing={!r}".format(self._signing))
        shown.append("access_delegation={!r}".format(self._access_delegation))
        return "IcebergCatalog({})".format(", ".join(shown))


class IcebergTable(_HoldsCredential):
    """One table of an `IcebergCatalog`, by namespace and name. Build one with
    `catalog.table(name)`."""

    __slots__ = ("_catalog", "_namespace", "_name")

    def __init__(self, catalog: IcebergCatalog, namespace: tuple[str, ...], name: str) -> None:
        if not isinstance(catalog, IcebergCatalog):
            raise TypeError("catalog must be a komira IcebergCatalog, not {}".format(type(catalog).__name__))
        if not isinstance(namespace, tuple) or not isinstance(name, str):
            raise TypeError("an IcebergTable is built by catalog.table(name)")
        _split_name(namespace + (name,))
        self._catalog = catalog
        self._namespace = namespace
        self._name = name

    @property
    def catalog(self) -> IcebergCatalog:
        """The catalog the table is in."""
        return self._catalog

    @property
    def namespace(self) -> tuple[str, ...]:
        """The namespace levels, outermost first."""
        return self._namespace

    @property
    def name(self) -> str:
        """The table's name within its namespace."""
        return self._name

    def __repr__(self) -> str:
        return "{!r}.table({!r})".format(self._catalog, self._namespace + (self._name,))


def iceberg(
    uri: str,
    *,
    warehouse: str | None = None,
    credential: _Credential | _BuiltIn = AMBIENT,
    signing: SigV4 | None = None,
    access_delegation: str = "vended-credentials",
) -> IcebergCatalog:
    """An Iceberg REST catalog at `uri` (http or https).

    `warehouse` names the warehouse to ask the catalog's config for.
    `credential` is the catalog's: `komira.AMBIENT` (the default),
    `komira.ANONYMOUS`, a `BearerToken` or an `OAuth2ClientCredentials`; with
    `signing=SigV4(region, service)`, `komira.AMBIENT` or an `AwsKeys`.
    `access_delegation` is 'vended-credentials' (the default: the catalog hands
    out credentials for the table's files) or 'none'. Building a catalog does
    no I/O.
    """
    return IcebergCatalog(
        uri,
        warehouse=warehouse,
        credential=credential,
        signing=signing,
        access_delegation=access_delegation,
    )


__all__ = ["ACCESS_DELEGATIONS", "IcebergCatalog", "IcebergTable", "SigV4", "iceberg"]
