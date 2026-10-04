# =============================================================================
# src/kci_pkg_upload/registry_set.mojo — `RegistrySet[T, C]`: THE substrate
#   ladder. One transport, one credential, four methods.
# =============================================================================
#
# `package_names(substrate, repo, subdir)` lists the package names a conda
# subdir holds; it takes the substrate like every other method, so the ladder
# stays the one place an arm is chosen, and a substrate with no subdir listing
# (PyPI) RAISES `no registry arm` rather than answering an empty set.
#
# WHY A LADDER AND NOT A TRAIT. Mojo 1.0 has no trait objects, so dispatching
# per substrate is an if-ladder over concrete arms whatever a trait would say.
# This struct holds that ladder, and it is the ONLY one in the package: every
# protocol struct (`PypiLegacyRegistry`, `PrefixDevRegistry`) is stateless and is reached only
# from here. A substrate with no arm RAISES
# `no registry arm for substrate <n>` — a local fault, before any request — so
# a totality test over every substrate goes RED on a missing arm rather than
# silently skipping it.
#
# `presence` is derived, once, from `read_back` + `identity_matches`, so no arm
# can answer "identical" by a rule of its own.
#
# ⛔ `upload` IS THE ONLY METHOD THAT CLAIMS A NAME, SO IT ALONE TAKES THE
# `ApprovedNames`, and asks it FIRST — before the substrate dispatch, before
# any credential is resolved, before any request is composed. A name the list
# does not hold RAISES naming the distribution, with the transport recording
# zero calls (`approved_names.mojo`). The list is an argument with no default:
# an upload that states none does not compile.
#
# WHO OWNS WHAT. A `RegistrySet` owns its transport and its credential by
# value. A caller that reads anonymously and writes with a credential, or reads
# from one registry and writes to another, holds TWO `RegistrySet` values with
# different credential instances.
#
# Encapsulation: owned values; the two accessors return borrows of values the
# caller supplied. No pointer, no wildcard origin.
# =============================================================================

from .approved_names import ApprovedNames
from .coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from .conda_repodata import NameListing
from .credential import RegistryCredential
from .identity import (
    IDENTITY_MATCH,
    IDENTITY_MISMATCH,
    ContentIdentity,
    identity_matches,
)
from .outcome import (
    PRESENCE_ABSENT,
    PRESENCE_AUTH_REFUSED,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_RATE_LIMITED,
    PRESENCE_UNKNOWN,
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    Fetched,
    Presence,
    ReadBack,
    UploadOutcome,
)
from .prefix_dev_registry import PrefixDevRegistry
from .pypi_registry import PypiLegacyRegistry
from .transport import PkgTransport


comptime SERVED_SUBSTRATES: String = "PUBLIC_PYPI and PREFIX_DEV_CONDA"
"""The substrates `RegistrySet` has an arm for, as a refusal names them."""


def no_registry_arm(substrate: Int) -> Error:
    """The refusal for a substrate this package has no arm for. Each method
    RAISES it where the ladder ends, so no method has a value to return for a
    missing arm. Every kind 0 is the permissive one (ABSENT, PRESENT,
    CREATED), so a placeholder return after a raising call would be a
    CREATED or PRESENT one refactor away from reachable."""
    return Error(
        String("no registry arm for substrate ")
        + String(substrate)
        + String(". kci_pkg_upload serves ")
        + String(SERVED_SUBSTRATES)
        + String("; the request was not sent")
    )


def presence_from_read_back(rb: ReadBack, expect: ContentIdentity) -> Presence:
    """The presence answer a read-back implies, compared FIELD BY FIELD
    against `expect` (NO_COMMON_FIELD is its own kind — see `identity.mojo`)."""
    if rb.kind == READ_PRESENT:
        var m = identity_matches(expect, rb.observed)
        var kind = PRESENCE_NO_COMMON_FIELD
        if m == IDENTITY_MATCH:
            kind = PRESENCE_PRESENT_IDENTICAL
        elif m == IDENTITY_MISMATCH:
            kind = PRESENCE_PRESENT_DIFFERENT
        var detail = rb.detail.copy()
        if kind != PRESENCE_PRESENT_IDENTICAL:
            detail = (
                String("ours ")
                + expect.describe()
                + String(" / the registry's ")
                + rb.observed.describe()
            )
        return Presence(kind, rb.status, rb.observed.copy(), detail^)
    var kind = PRESENCE_UNKNOWN
    if rb.kind == READ_ABSENT:
        kind = PRESENCE_ABSENT
    elif rb.kind == READ_AUTH_REFUSED:
        kind = PRESENCE_AUTH_REFUSED
    elif rb.kind == READ_RATE_LIMITED:
        kind = PRESENCE_RATE_LIMITED
    return Presence(kind, rb.status, ContentIdentity.none(), rb.detail.copy())


struct RegistrySet[T: PkgTransport, C: RegistryCredential](Movable, Deinitable):
    """The single substrate dispatch (see the file header).

    Layout: the transport and the credential by value. No pointer field."""

    var _transport: Self.T
    var _cred: Self.C

    def __init__(out self, var transport: Self.T, var cred: Self.C):
        self._transport = transport^
        self._cred = cred^

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport, so a falsifier can assert over the exact
        conversation — the `&self.inner` accessor, not an escape hatch."""
        return self._transport

    def credential(ref self) -> ref [self._cred] Self.C:
        """Borrow the credential (a test asserts which surfaces were asked)."""
        return self._cred

    def presence(
        mut self, c: PackageCoordinate, expect: ContentIdentity
    ) raises -> Presence:
        """Is `c` there, and is it `expect`? Derived from `read_back`."""
        var rb = self.read_back(c)
        return presence_from_read_back(rb, expect)

    def upload(
        mut self, f: PackageFile, names: ApprovedNames
    ) raises -> UploadOutcome:
        """Upload `f`. RAISES, before anything else, when `names` does not
        approve `f`'s distribution: a published name is claimed for good."""
        names.refuse_unapproved(f.coordinate)
        var s = f.coordinate.substrate
        if s == SUBSTRATE_PUBLIC_PYPI:
            return PypiLegacyRegistry.upload(self._transport, self._cred, f)
        if s == SUBSTRATE_PREFIX_DEV_CONDA:
            return PrefixDevRegistry.upload(self._transport, self._cred, f)
        raise no_registry_arm(s)

    def read_back(mut self, c: PackageCoordinate) raises -> ReadBack:
        if c.substrate == SUBSTRATE_PUBLIC_PYPI:
            return PypiLegacyRegistry.read_back(self._transport, self._cred, c)
        if c.substrate == SUBSTRATE_PREFIX_DEV_CONDA:
            return PrefixDevRegistry.read_back(self._transport, self._cred, c)
        raise no_registry_arm(c.substrate)

    def fetch(mut self, c: PackageCoordinate) raises -> Fetched:
        if c.substrate == SUBSTRATE_PUBLIC_PYPI:
            return PypiLegacyRegistry.fetch(self._transport, self._cred, c)
        if c.substrate == SUBSTRATE_PREFIX_DEV_CONDA:
            return PrefixDevRegistry.fetch(self._transport, self._cred, c)
        raise no_registry_arm(c.substrate)

    def package_names(
        mut self, substrate: Int, repo: String, subdir: String
    ) raises -> NameListing:
        """The package names `repo`'s `subdir` holds a file under. Only a
        conda channel has subdir listings; any other substrate RAISES."""
        if substrate == SUBSTRATE_PREFIX_DEV_CONDA:
            return PrefixDevRegistry.package_names(
                self._transport, self._cred, repo, subdir
            )
        raise no_registry_arm(substrate)
