# =============================================================================
# kci_revision/artifact_types.mojo — THE ARTIFACT-TYPE TABLE.
#   Layer 1 of kci's artifact types: one row per revision ROLE, holding only
#   what is true of that type everywhere.
# =============================================================================
#
# ★ AN ARTIFACT TYPE IS A ROW OF THIS TABLE, KEYED BY THE ROLE A REVISION ALREADY
# RECORDS (`RevisionArtifact.role`). There is no proto enum, no `BuildTarget`
# field and no `RevisionArtifact` field for it. The bundle schema already says
# where the distinction lives ("WHAT the file is belongs to the artifact's
# ROLE"), and a parallel kind enum would be a second vocabulary kept in agreement
# with the first by hand. So THIS LIST IS THE ONLY LIST OF TYPES, and every
# consumer that needs "all types" iterates `artifact_type_rows()`.
#
# ⛔ A ROLE WITH NO ROW IS REFUSED, NEVER IGNORED (`row_for_role`). Ignoring it is
# the defect this table exists to close: a stage step that knows three roles and
# skips the rest stages a revision's probes, skips every package, and exits 0.
#
# ★ THE `stage_leg` COLUMN HOLDS THE LEG *BIT*, AND THE TRANSPORT IS DERIVED FROM
# IT (`STAGE_TRANSPORT_*_LEGS`). SERVICE and PROBE are separate bits ON PURPOSE:
# the stage binding tells them apart (a probe is staged INTO an env's own
# registry, so a probe needs `--env` and a same-env service copy does not).
# Merging them into one "OCI copy" value would erase that distinction.
#
# ⚠ ONLY ROLES WHOSE PURPOSE FIXES THEIR SHAPE BELONG HERE (a `python_wheel` is
# always a wheel). An artifact whose purpose admits several shapes — a
# zip-shaped `service`, say — is NOT a row: it needs a separate output-format
# shape axis, and a new role for it would break every `has_role(rec, "service")`
# consumer.
#
# ⚠ WHY A MODULE OF ITS OWN. `__init__.mojo` is already past two thousand lines,
# and the table is consumed by the stage decision (kci's revision CLI) and,
# later, by the package classifier and stager. A module keeps it one import away
# from each, without growing the record's file.
#
# Encapsulation: flat value structs (owned Strings + Ints), ZERO UnsafePointer,
# ZERO wildcard origins, ZERO FFI, no I/O. Mojo 1.0 (def-only).
# =============================================================================

from . import (
    REVISION_ROLE_PROBE,
    REVISION_ROLE_SERVICE,
    REVISION_ROLE_WEB_CONTENT,
)


# =============================================================================
# §1 — the roles this module adds. The three image/content roles are declared in
#      `__init__.mojo`, beside `RevisionArtifact`, and are only READ here.
# =============================================================================

comptime REVISION_ROLE_PYTHON_WHEEL: String = "python_wheel"
"""A Python wheel (`<dist>-<ver>-py3-none-<plat>.whl`), uploaded to a PEP 503
index. Its version is PEP 440 `1.1.N` with NO local segment."""

comptime REVISION_ROLE_CONDA_PACKAGE: String = "conda_package"
"""A `.conda` archive. ⚠ Its FILENAME does not carry the platform: a conda
channel keys a package by (subdir, file_name), which is why every package key in
this module carries the subdir (`package_file_key`)."""

comptime REVISION_ROLE_NPM_PACKAGE: String = "npm_package"
"""An npm tarball (`<name>-<ver>.tgz`). Always subdir `noarch`."""

comptime REVISION_ROLE_PACKAGE_STAMP_TOOL: String = "package_stamp_tool"
"""The version-stamp tool's own digest. The row is kept so the table is
complete: never staged and never published, so its stage leg is NONE.

⚠ NO WRITER RECORDS IT. No store mints a package's N: N is the commit position
of the published set's naming commit on main, stamped by the release build at
`--commit`. The stamp tool is in that input closure, so a change to it moves N
when it lands, and the tool's digest is recorded with the release's provenance,
not in any artifact set."""


# =============================================================================
# §2 — the stage-leg bits, and the transport each one is carried by.
#
# The first three bits are the ones `stage` has always had; they live here rather
# than in kci's revision CLI (which re-exports them) because the table's
# `stage_leg` column must be able to name them, and this library cannot import
# that CLI source.
# =============================================================================

comptime STAGE_LEG_NONE: Int = 0
"""A role that is recorded in the artifact set and never staged
(`package_stamp_tool`)."""

comptime STAGE_LEG_WEB: Int = 1
"""The web-content RECORD leg (`staged-content/<web_slug>`)."""

comptime STAGE_LEG_SERVICE: Int = 2
"""The OCI crane-copy-by-digest leg + `staged-image/<app>`."""

comptime STAGE_LEG_PROBE: Int = 4
"""The validate-wave probe copy leg + `staged-image/<probe>` per probe.

⛔ THIS BIT IS WHAT MADE A PROBE-ONLY REVISION STAGEABLE. The probe leg ran ONLY
as a rider inside the service leg, so a revision carrying probes and no service
was refused as if it carried nothing at all."""

comptime STAGE_LEG_PACKAGE: Int = 8
"""The package-registry upload leg (wheels, conda archives, npm tarballs)."""

comptime DECLARED_STAGE_LEGS: Int = (
    STAGE_LEG_WEB | STAGE_LEG_SERVICE | STAGE_LEG_PROBE | STAGE_LEG_PACKAGE
)
"""Every leg bit this module declares. A table row whose leg is outside this set
(and is not NONE) is a row nothing can route."""

comptime STAGE_TRANSPORT_CONTENT_LEGS: Int = STAGE_LEG_WEB
"""The legs carried by the content-record transport."""

comptime STAGE_TRANSPORT_OCI_LEGS: Int = STAGE_LEG_SERVICE | STAGE_LEG_PROBE
"""The legs carried by the OCI copy-by-digest transport. Two bits, one transport:
the transport is shared, the leg is not."""

comptime STAGE_TRANSPORT_PACKAGE_LEGS: Int = STAGE_LEG_PACKAGE
"""The legs carried by the package-registry upload transport."""


def stage_leg_names(legs: Int) -> String:
    """`WEB|PROBE` — the bits of `legs`, in bit order, for an error message an
    operator can act on. `NONE` for zero. A bit this module does not declare is
    printed as its value, so an unknown leg is visible rather than dropped."""
    if legs == STAGE_LEG_NONE:
        return String("NONE")
    var out = String("")
    var rest = legs
    if (rest & STAGE_LEG_WEB) != 0:
        out += String("WEB")
        rest &= ~STAGE_LEG_WEB
    if (rest & STAGE_LEG_SERVICE) != 0:
        if out.byte_length() > 0:
            out += String("|")
        out += String("SERVICE")
        rest &= ~STAGE_LEG_SERVICE
    if (rest & STAGE_LEG_PROBE) != 0:
        if out.byte_length() > 0:
            out += String("|")
        out += String("PROBE")
        rest &= ~STAGE_LEG_PROBE
    if (rest & STAGE_LEG_PACKAGE) != 0:
        if out.byte_length() > 0:
            out += String("|")
        out += String("PACKAGE")
        rest &= ~STAGE_LEG_PACKAGE
    if rest != 0:
        if out.byte_length() > 0:
            out += String("|")
        out += String("UNDECLARED(") + String(rest) + String(")")
    return out^


# =============================================================================
# §3 — the type names (the `type` column).
# =============================================================================

comptime ARTIFACT_TYPE_OCI_IMAGE: String = "OCI_IMAGE"
comptime ARTIFACT_TYPE_CONTENT_BLOB: String = "CONTENT_BLOB"
comptime ARTIFACT_TYPE_PYTHON_WHEEL: String = "PYTHON_WHEEL"
comptime ARTIFACT_TYPE_CONDA_PACKAGE: String = "CONDA_PACKAGE"
comptime ARTIFACT_TYPE_NPM_PACKAGE: String = "NPM_PACKAGE"
comptime ARTIFACT_TYPE_BUILD_TOOL: String = "BUILD_TOOL"


# =============================================================================
# §4 — THE TABLE.
# =============================================================================


@fieldwise_init
struct ArtifactTypeRow(Copyable, Movable, Deinitable):
    """ONE artifact type — what is true of it EVERYWHERE (layer 1). Where it is
    placed per channel is layer 2 and does not live here.

      * `role`             — the `RevisionArtifact.role` string; the table's key.
      * `type_name`        — `ARTIFACT_TYPE_*`. SERVICE and PROBE share one.
      * `stage_leg`        — ONE `STAGE_LEG_*` bit, or `STAGE_LEG_NONE`.
      * `file_suffix`      — what a file of this type ends with, or "" when the
                             artifact is not a file (an image manifest).
      * `filename_grammar` — the name a registry sees, as prose.
      * `version_grammar`  — where the version lives, as prose.

    Flat Strings + one Int; the table is a typed `List`."""

    var role: String
    var type_name: String
    var stage_leg: Int
    var file_suffix: String
    var filename_grammar: String
    var version_grammar: String


def artifact_type_rows() -> List[ArtifactTypeRow]:
    """THE ONLY LIST OF ARTIFACT TYPES. Every totality check iterates this.

    Adding a row is adding a type. What else that costs (a classifier arm, a
    stamp arm, a placement, a registry client) lives outside this table; the
    part that is enforced HERE is that a row's leg must be a declared bit and
    that the stage binding must wire it before a record carrying it can be
    staged (the revision CLI's `drive_stage`)."""
    var rows = List[ArtifactTypeRow]()
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_SERVICE),
            String(ARTIFACT_TYPE_OCI_IMAGE),
            STAGE_LEG_SERVICE,
            String(""),
            String("an OCI manifest, addressed `sha256:`; named by the app/service id"),
            String("none in the bytes"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_PROBE),
            String(ARTIFACT_TYPE_OCI_IMAGE),
            STAGE_LEG_PROBE,
            String(""),
            String(
                "an OCI manifest, addressed `sha256:`; named by the probe's"
                " `from_build` name"
            ),
            String("none in the bytes"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_WEB_CONTENT),
            String(ARTIFACT_TYPE_CONTENT_BLOB),
            STAGE_LEG_WEB,
            String(""),
            String("a tarball or file, addressed `content-sha256:`; named by the app id"),
            String("none"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_PYTHON_WHEEL),
            String(ARTIFACT_TYPE_PYTHON_WHEEL),
            STAGE_LEG_PACKAGE,
            String(".whl"),
            String("<dist>-<ver>-py3-none-<plat>.whl, one per subdir"),
            String("PEP 440 <prefix>.N, no local segment"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_CONDA_PACKAGE),
            String(ARTIFACT_TYPE_CONDA_PACKAGE),
            STAGE_LEG_PACKAGE,
            String(".conda"),
            String(
                "<subdir>/<name>-<ver>-<build>.conda; the file name alone does NOT"
                " carry the platform"
            ),
            String("<prefix>.N"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_NPM_PACKAGE),
            String(ARTIFACT_TYPE_NPM_PACKAGE),
            STAGE_LEG_PACKAGE,
            String(".tgz"),
            String("<name>-<ver>.tgz, subdir noarch"),
            String("semver <prefix>.N"),
        )
    )
    rows.append(
        ArtifactTypeRow(
            String(REVISION_ROLE_PACKAGE_STAMP_TOOL),
            String(ARTIFACT_TYPE_BUILD_TOOL),
            STAGE_LEG_NONE,
            String(""),
            String(
                "the stamp tool's single joined output, addressed"
                " `content-sha256:`; recorded, never staged or published"
            ),
            String("none"),
        )
    )
    return rows^


def known_roles_text() -> String:
    """`service, probe, …` — every role the table knows, in table order."""
    var rows = artifact_type_rows()
    var out = String("")
    for i in range(len(rows)):
        if i > 0:
            out += String(", ")
        out += rows[i].role
    return out^


def stageable_roles_text() -> String:
    """The roles whose leg is not NONE, in table order — what a "nothing to
    stage" refusal lists, derived rather than restated so it cannot go stale the
    way a hand-typed "`service` or `web_content`" did."""
    var rows = artifact_type_rows()
    var out = String("")
    for i in range(len(rows)):
        if rows[i].stage_leg == STAGE_LEG_NONE:
            continue
        if out.byte_length() > 0:
            out += String(", ")
        out += String("`") + rows[i].role + String("`")
    return out^


def row_for_role(role: String) raises -> ArtifactTypeRow:
    """The row for `role`. RAISES for a role with no row, naming it and every
    role the table knows.

    ⛔ NEVER A DEFAULT. A missing row answered as "no leg" is precisely how an
    unknown role used to vanish from `stage`: the other legs ran, the unknown
    artifact was skipped, and the verb exited 0. The record decoder accepts any
    role string (a newer binary may have minted it), so this is the one place
    that decides what an unknown one means, and it means STOP."""
    var rows = artifact_type_rows()
    for i in range(len(rows)):
        if rows[i].role == role:
            return rows[i].copy()
    raise Error(
        String("kci revision: role '")
        + role
        + String(
            "' has no row in the artifact-type table (kci_revision/"
            "artifact_types.mojo), so no verb knows how to stage, validate or"
            " publish it. It is REFUSED rather than skipped: a skipped artifact is"
            " a partial release that exits 0. Known roles: "
        )
        + known_roles_text()
        + String(
            ". If a newer kci minted this revision, use that binary."
        )
    )


# =============================================================================
# §5 — the package version, and the per-file key.
# =============================================================================


def _all_digits(s: String) -> Bool:
    """True iff `s` is a non-empty run of ASCII digits."""
    var bytes = s.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var b = bytes[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return False
    return True


def package_version(prefix: String, n: Int) raises -> String:
    """`<prefix>.<n>` — the version a package file ships with when its N is `n`
    (`1.1` + 7 -> `1.1.7`).

    N is not minted by any store. It is the commit position of the published
    set's naming commit on main (`git rev-list --count --first-parent`), which
    the release build stamps into the files at `--commit`.

    REFUSES `n <= 0`. 0 is the constant SENTINEL every producer builds
    (`<prefix>.0`), which a build without `--commit` keeps and the stamp at
    `--commit` rewrites to N; a file that ships `<prefix>.0` was never stamped,
    and two unrelated builds would share its filename. REFUSES a prefix that is
    not exactly two dot-separated runs of digits, since N must land in the PATCH
    position for `1.1 -> 1.2` to continue the sequence rather than restart it."""
    if n <= 0:
        raise Error(
            String("kci package: version number N=")
            + String(n)
            + String(
                " is refused. N=0 is the build SENTINEL (every producer builds"
                " <prefix>.0, and only the stamp at --commit rewrites it), so a"
                " shipped version must carry N >= 1: the commit position the"
                " release build stamps."
            )
        )
    var parts = prefix.split(String("."))
    var ok = len(parts) == 2
    if ok:
        ok = _all_digits(String(parts[0])) and _all_digits(String(parts[1]))
    if not ok:
        raise Error(
            String("kci package: version prefix '")
            + prefix
            + String(
                "' is refused: it must be MAJOR.MINOR (two runs of digits), so"
                " that N is the PATCH component."
            )
        )
    return prefix + String(".") + String(n)


comptime PACKAGE_SUBDIR_LINUX_64: String = "linux-64"
comptime PACKAGE_SUBDIR_OSX_ARM64: String = "osx-arm64"
comptime PACKAGE_SUBDIR_NOARCH: String = "noarch"


def package_subdirs() -> List[String]:
    """The closed subdir vocabulary a package key may carry. A wheel's subdir is
    the platform its build ran under, conda's is `index.json`'s own `subdir`,
    npm's is always `noarch`."""
    var out = List[String]()
    out.append(String(PACKAGE_SUBDIR_LINUX_64))
    out.append(String(PACKAGE_SUBDIR_OSX_ARM64))
    out.append(String(PACKAGE_SUBDIR_NOARCH))
    return out^


def package_file_key(subdir: String, file_name: String) raises -> String:
    """`<subdir>/<file_name>` — THE key kci uses for one package file,
    uniformly across the three package types.

    ★ THE SUBDIR IS PART OF THE KEY BECAUSE A CONDA FILENAME DOES NOT CARRY THE
    PLATFORM. The linux-64 and osx-arm64 builds of one conda package may share a
    file name (whether rattler's build-string hash differs per platform has not
    been measured), and a channel keys them by (subdir, file_name). A key on the
    file name alone would give two different files one key, and the second
    would be refused as "differs" — or, worse, a reader would take one for the
    other.

    REFUSES a subdir outside the closed vocabulary, and an empty file name or
    one containing `/` (the separator would make two different pairs render to
    one key)."""
    var known = False
    var subs = package_subdirs()
    for i in range(len(subs)):
        if subs[i] == subdir:
            known = True
            break
    if not known:
        raise Error(
            String("kci package: subdir '")
            + subdir
            + String("' is not one of linux-64, osx-arm64, noarch")
        )
    if file_name.byte_length() == 0 or file_name.find(String("/")) >= 0:
        raise Error(
            String("kci package: file name '")
            + file_name
            + String(
                "' is refused: it must be non-empty and carry no '/', since the"
                " subdir is the only path component of a package key"
            )
        )
    return subdir + String("/") + file_name
