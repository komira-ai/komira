# =============================================================================
# src/kci_pkg_upload/approved_names.mojo — WHICH names may be uploaded at
#   all: `ApprovedNames`, an exact allow-list the caller supplies as data.
# =============================================================================
#
# ⛔ A PUBLISHED NAME IS A ONE-WAY DOOR. PyPI, a conda channel and npm are each
# ONE flat namespace, and a name uploaded there is claimed for good: a deleted
# release's file name can never be reused. So a name nobody decided to publish
# must be refused BEFORE it is claimed, not found afterwards.
# `RegistrySet.upload` asks this list first, before it resolves a credential or
# composes a request: an unapproved name RAISES naming the distribution, and
# the transport records zero calls.
#
# THE LIST IS DATA, AND IT IS EXACT. This package names no prefix and no
# project: the caller reads the approved names from wherever it keeps them and
# states them here, once per upload. There is no default and no "any name"
# list, so a caller that forgot to state one does not compile, and an EMPTY
# list approves nothing.
#
# THE COMPARISON IS THE REGISTRY'S. A python index keys a project by its PEP 503
# normalised name (`normalize_distribution_name`): `foo_bar`, `Foo-Bar` and
# `foo.bar` are ONE project, so they are one name here. A conda channel keys a
# package by its lowercase name and keeps `-`, `_` and `.` distinct, so the
# comparison there is ASCII-case-insensitive and nothing more. Every substrate
# that is not a python index is compared the conda way, the stricter of the two.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from .coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    normalize_distribution_name,
    substrate_name,
)
from .identity import ascii_lower


def is_python_index(substrate: Int) -> Bool:
    """True for a substrate whose names are compared under PEP 503."""
    return substrate == SUBSTRATE_PUBLIC_PYPI


def approved_name_key(name: String, substrate: Int) -> String:
    """The form in which `name` is compared on `substrate` (see the header)."""
    if is_python_index(substrate):
        return normalize_distribution_name(name)
    return ascii_lower(name)


struct ApprovedNames(Copyable, Movable, Deinitable):
    """The exact names an upload may claim. Built empty, then `approve(name)`
    once per name; an empty list approves nothing.

    `approve` RAISES on a statement that would admit more or less than it
    says: an empty name, a name holding whitespace or a `/`, or a name stated
    twice (ASCII-case-insensitively).

    Layout: an owned list of Strings. No pointer field."""

    var _names: List[String]

    def __init__(out self):
        self._names = List[String]()

    def approve(mut self, var name: String) raises:
        if name.byte_length() == 0:
            raise Error(
                String("kci_pkg_upload: an EMPTY approved name. The list names")
                + String(" exactly the packages it approves")
            )
        var b = name.as_bytes()
        for i in range(len(b)):
            var c = b[i]
            if (
                c == UInt8(ord(" "))
                or c == UInt8(ord("\t"))
                or c == UInt8(ord("\n"))
                or c == UInt8(ord("\r"))
                or c == UInt8(ord("/"))
            ):
                raise Error(
                    String("kci_pkg_upload: approved name '")
                    + name
                    + String("' holds whitespace or '/'; a package name is one")
                    + String(" word")
                )
        var key = ascii_lower(name)
        for i in range(len(self._names)):
            if ascii_lower(self._names[i]) == key:
                raise Error(
                    String("kci_pkg_upload: '")
                    + name
                    + String("' is approved twice (as '")
                    + self._names[i]
                    + String("')")
                )
        self._names.append(name^)

    def count(self) -> Int:
        return len(self._names)

    def is_approved(self, distribution: String, substrate: Int) -> Bool:
        var key = approved_name_key(distribution, substrate)
        for i in range(len(self._names)):
            if approved_name_key(self._names[i], substrate) == key:
                return True
        return False

    def refusal(self, distribution: String, substrate: Int) -> String:
        """EMPTY when `distribution` may be uploaded to `substrate`; otherwise
        the refusal text, naming the distribution and the substrate."""
        if distribution.byte_length() > 0 and self.is_approved(
            distribution, substrate
        ):
            return String("")
        return (
            String("kci_pkg_upload: published name '")
            + distribution
            + String("' is not in the approved-names list (")
            + String(len(self._names))
            + String(" approved) for ")
            + substrate_name(substrate)
            + String(
                ". The request was not sent: an uploaded name is claimed for"
                " good, so a name is added to the list deliberately, never"
                " uploaded first"
            )
        )

    def refuse_unapproved(self, c: PackageCoordinate) raises:
        """RAISE `refusal` for `c`'s distribution on `c`'s substrate — a local
        fault, before any request is composed."""
        var why = self.refusal(c.distribution, c.substrate)
        if why.byte_length() > 0:
            raise Error(why^)
