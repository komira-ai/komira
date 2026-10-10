# =============================================================================
# src/kci_release_set/closure.mojo -- requirement closure by NAME: every
#   package a library of the set requires is another library of the set.
# =============================================================================
#
# `undeclared_requirements(members)` returns one line per requirement of a
# CONDA library member whose package name is not the conda name of ANOTHER
# library member. Skipped: virtual packages (a name starting `__`: the
# platform guard, `__linux` / `__osx`) and the compiler pin
# (`MOJO_COMPILER_PACKAGE`); and a requirement byte-equal to one of the
# conda-forge requirements of the system libraries a library may open
# (system_libs.mojo, held to tools/build/package/system_libs.bzl:
# `zstd >=1.5.2,<2`; `zstd >=1.0`, `zstd`, `ZSTD >=1.5.2,<2` and
# `conda-forge::zstd >=1.5.2,<2` are listed; one given more than once is
# listed once, as PUBLISH refuses it). A requirement's name is the text
# before its first space (`komira_hash ==1.0.0 h0_7` names `komira_hash`). A library
# requiring itself, or requiring the metapackage, is listed: neither is
# another library. Only libraries are read: the metapackage's requirements
# are its members, and PUBLISH checks those rows; a non-CONDA member has none.
#
# Why BUILD needs it: the package rule writes a library's direct
# dependencies into its `depends`, and a release set is a hand-written list.
# A dependency nobody declared (or one the packer refused, e.g. a library
# that loads a shared library by name) would otherwise reach a channel as a
# package nobody can install. The BUILD step refuses such a set before it
# writes release.json; the PUBLISH step's `require_closure` checks the same
# names again together with the exact version and build pins.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_set.conda_metadata import KIND_LIBRARY
from kci_release_set.member import ReleaseMember
from kci_release_set.system_libs import is_system_lib_requirement


comptime MOJO_COMPILER_PACKAGE: String = "mojo-compiler"
"""The conda name of the compiler every library pins exactly."""


def requirement_name(requirement: String) -> String:
    """The package name of a conda requirement: the text before its first
    space, or all of it."""
    var sp = requirement.find(String(" "))
    if sp < 0:
        return requirement.copy()
    return String(requirement[byte=:sp])


def _is_other_library(members: List[ReleaseMember], name: String, own: Int) -> Bool:
    for j in range(len(members)):
        if j == own:
            continue
        ref m = members[j]
        if m.has_conda and m.conda.kind == KIND_LIBRARY and m.conda.name == name:
            return True
    return False


def undeclared_requirements(members: List[ReleaseMember]) -> List[String]:
    """One line per library requirement that names no other library of
    `members` (file header); EMPTY when the set is closed."""
    var out = List[String]()
    for i in range(len(members)):
        ref m = members[i]
        if not m.has_conda or m.conda.kind != KIND_LIBRARY:
            continue
        for d in range(len(m.conda.depends)):
            ref dep = m.conda.depends[d]
            var name = requirement_name(dep)
            if name.startswith(String("__")) or name == MOJO_COMPILER_PACKAGE:
                continue
            if _is_other_library(members, name, i):
                continue
            if is_system_lib_requirement(dep):
                var earlier = 0
                for k in range(d):
                    if m.conda.depends[k] == dep:
                        earlier += 1
                if earlier == 1:  # said once, at its second occurrence
                    out.append(
                        String("artifact '") + m.artifact + String("' requires '") + dep
                        + String("' more than once")
                    )
                continue
            out.append(
                String("artifact '")
                + m.artifact
                + String("' requires '")
                + dep
                + String("', and '")
                + name
                + String("' is not another library of this release set")
                + String(" (nor a system library requirement of")
                + String(" tools/build/package/system_libs.bzl)")
            )
    return out^
