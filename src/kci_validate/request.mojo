# =============================================================================
# src/kci_validate/request.mojo -- what one validation is given, and the
#   release it checks, read the way the PUBLISH step reads it.
# =============================================================================
#
# `ValidateRequest` is one validation of one PUBLISH step: the step's inputs
# (artifacts, channels file, channel, platform), the run's (release
# directory, revision, scratch directory, the repository root: where a
# CONDA_INSTALL_SMOKE program is read from, and what an ENV scratch directory
# must not be inside; --plan; for CONDA_INSTALL_ENV, --pixi and
# --pixi-sha256) and the validation itself (kci_release_machine's
# `StageValidation`).
#
# `ContainerHost` is how this machine starts the container: the docker
# program, the PATH the docker CLI gets, and the `uid:gid` the container runs
# as (the caller's own, so what it writes into the mount is readable after).
#
# `load_validated_release` reads the release the validation checks, with the
# PUBLISH step's own rules: the artifacts file, the release directory of
# the step's platform (`<release-dir>/<platform>`), release.json's revision
# equal to --revision-id, every member verified (kci_publish
# `load_release`). Then the channel's CONDA location from the channels file.
# Each refusal RAISES with the reason; the caller turns it into a failed
# check, never a skip.
#
# `install_pins` turns the validation's `install` names into what must be
# installed: each name's version, build, sha256 and subdir from release.json,
# its file name, and for a library its payload path and payload sha256, its
# import name and build label, and the sha256 its `doc_files` records for
# share/doc/<name>/README.md ("" when it records none) from its
# metadata.json. `mojo_pin_of` is the compiler version every library of
# the set was built with (they must agree). A name that is not a member, a
# member that is not a conda package, or a value that could not be put in a
# shell word safely RAISES.
#
# `with_members` adds, after the named pins, every member of a named
# METAPACKAGE, so a validation that installs only the metapackage checks
# every library it brings. The member list is read from the built
# metapackage's own `depends` (its metadata.json, the requirements the
# packer wrote: the platform guard, then `<member> ==<version> <build>` for
# each member): each requirement must be at the version and build
# release.json records for that name, and the list must EQUAL the release
# set's conda libraries. An empty list, a requirement of another shape, a
# name that is not a library of the set, another version or build, and a
# library of the set the metapackage does not require each RAISE, naming
# it: a metapackage that brings nothing is never a vacuous pass.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os.path import exists

from kci_artifact import read_artifacts
from kci_api import release_platform_dir
from kci_publish.inputs import LoadedRelease, load_release
from kci_release_channel import ARTIFACT_TYPE_CONDA, find_channel, parse_channels_file
from kci_release_set.conda_metadata import KIND_LIBRARY, KIND_METAPACKAGE
from kci_release_set.release_manifest import RELEASE_MANIFEST_NAME, read_release_manifest
from kci_release_machine import StageValidation


struct ValidateRequest(Copyable, Movable):
    """One validation of one PUBLISH step (file header).

    Layout: owned values only. No pointer field."""

    var stage: String
    var step_name: String
    var validation: StageValidation
    var artifacts_file: String
    var channels_file: String
    var channel: String
    var release_dir: String
    var platform: String
    var revision_id: String
    var scratch_dir: String
    var repo_root: String
    var plan: Bool
    var pixi: String
    var pixi_sha256: String

    def __init__(out self, var validation: StageValidation):
        self.stage = String("")
        self.step_name = String("")
        self.validation = validation^
        self.artifacts_file = String("")
        self.channels_file = String("")
        self.channel = String("")
        self.release_dir = String("")
        self.platform = String("")
        self.revision_id = String("")
        self.scratch_dir = String("")
        self.repo_root = String(".")
        self.plan = False
        self.pixi = String("")
        self.pixi_sha256 = String("")


struct ContainerHost(Copyable, Movable):
    """How this machine starts the container (file header).

    Layout: owned Strings. No pointer field."""

    var docker: String
    var path_env: String
    var user: String

    def __init__(out self, var docker: String, var path_env: String, var user: String):
        self.docker = docker^
        self.path_env = path_env^
        self.user = user^


struct ValidatedRelease(Movable):
    """The release a validation checks and the channel's location.

    Layout: owned values only. No pointer field."""

    var loaded: LoadedRelease
    var channel_url: String

    def __init__(out self, var loaded: LoadedRelease, var channel_url: String):
        self.loaded = loaded^
        self.channel_url = channel_url^


def load_validated_release(req: ValidateRequest) raises -> ValidatedRelease:
    """The release and the channel location (file header). RAISES with the
    reason."""
    var arts = read_artifacts(req.artifacts_file)
    var dir = release_platform_dir(req.release_dir, req.platform)
    var manifest_path = dir + String("/") + String(RELEASE_MANIFEST_NAME)
    if not exists(manifest_path):
        raise Error(String("no ") + manifest_path + String(": nothing was built for platform ") + req.platform)
    var recorded = read_release_manifest(manifest_path)
    if recorded.revision != req.revision_id:
        raise Error(
            String("the release in '") + dir + String("' was built from revision ") + recorded.revision
            + String(", not --revision-id ") + req.revision_id
        )
    var loaded = load_release(arts, dir)
    var text: String
    try:
        text = open(req.channels_file, "r").read()
    except e:
        raise Error(String("channels file '") + req.channels_file + String("' cannot be read: ") + String(e))
    var channel = find_channel(parse_channels_file(text), req.channel)
    var url = channel.repository_for(String(ARTIFACT_TYPE_CONDA)).location.copy()
    while url.endswith(String("/")):
        var trimmed = String(url[byte = 0 : url.byte_length() - 1])
        url = trimmed^
    return ValidatedRelease(loaded^, url^)


struct InstallPin(Copyable, Movable):
    """One package the validation installs, pinned to the release's own
    (file header). `payload_path` and `payload_sha256` are "" for a
    metapackage.

    Layout: owned Strings and a Bool. No pointer field."""

    var name: String
    var version: String
    var build: String
    var sha256: String
    var subdir: String
    var is_library: Bool
    var payload_path: String
    var payload_sha256: String
    var import_name: String
    var label: String
    var has_doc_files: Bool
    var readme_sha256: String

    def __init__(out self, var name: String):
        self.name = name^
        self.version = String("")
        self.build = String("")
        self.sha256 = String("")
        self.subdir = String("")
        self.is_library = False
        self.payload_path = String("")
        self.payload_sha256 = String("")
        self.import_name = String("")
        self.label = String("")
        self.has_doc_files = False
        self.readme_sha256 = String("")

    def file_name(self) -> String:
        """`<name>-<version>-<build>.conda`: the file the channel serves."""
        return self.name + String("-") + self.version + String("-") + self.build + String(".conda")


def readme_doc_path(conda_name: String) -> String:
    """`share/doc/<conda name>/README.md`: where a library's package installs
    its README (metadata.json `doc_files`)."""
    return String("share/doc/") + conda_name + String("/README.md")


def _shell_safe(s: String) -> Bool:
    """`[A-Za-z0-9._+-]` and `/` only, no empty or `..` segment, not
    absolute: a value kci writes into the container's script."""
    var b = s.as_bytes()
    if len(b) == 0 or Int(b[0]) == 47:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (
            (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
            or c == 46 or c == 95 or c == 43 or c == 45 or c == 47
        )
        if not ok:
            return False
    var segments = s.split(String("/"))
    for i in range(len(segments)):
        var seg = String(segments[i])
        if seg.byte_length() == 0 or seg == String(".") or seg == String(".."):
            return False
    return True


def install_pins(release: LoadedRelease, names: List[String]) raises -> List[InstallPin]:
    """Each name of `names`, pinned (file header). RAISES naming the first
    name that is not a conda member of the release set."""
    var out = List[InstallPin]()
    for n in range(len(names)):
        ref name = names[n]
        var found = False
        for i in range(len(release.recomputed.entries)):
            ref e = release.recomputed.entries[i]
            if e.name != name:
                continue
            if e.artifact_type != ARTIFACT_TYPE_CONDA:
                raise Error(String("'") + name + String("' is a member of the release set but not a conda package"))
            var pin = InstallPin(name.copy())
            pin.version = e.version.copy()
            pin.build = e.build.copy()
            pin.sha256 = e.sha256_hex.copy()
            pin.subdir = e.subdir.copy()
            for m in range(len(release.members)):
                ref mem = release.members[m]
                if mem.has_conda and mem.conda.name == name and mem.conda.kind == KIND_LIBRARY:
                    pin.is_library = True
                    pin.payload_path = mem.conda.payload_path.copy()
                    pin.payload_sha256 = mem.conda.payload_sha256.copy()
                    pin.import_name = mem.conda.import_name.copy()
                    pin.label = mem.conda.label.copy()
                    pin.has_doc_files = mem.conda.has_doc_files
                    var readme = readme_doc_path(name)
                    for d in range(len(mem.conda.doc_files)):
                        if mem.conda.doc_files[d].path == readme:
                            pin.readme_sha256 = mem.conda.doc_files[d].sha256_hex.copy()
            for word in [pin.version.copy(), pin.build.copy(), pin.subdir.copy()]:
                if not _shell_safe(word):
                    raise Error(String("'") + name + String("' has a version, build or subdir '") + word + String("' kci will not write into a script"))
            if pin.is_library and not _shell_safe(pin.payload_path):
                raise Error(
                    String("'") + name + String("' has payload_path '") + pin.payload_path
                    + String("', which is not a relative path kci will write into a script")
                )
            out.append(pin^)
            found = True
            break
        if not found:
            var members = String("")
            for i in range(len(release.recomputed.entries)):
                if i > 0:
                    members += String(" ")
                members += release.recomputed.entries[i].name
            raise Error(String("'") + name + String("' is not a member of the release set (") + members + String(")"))
    return out^


def _has_pin(pins: List[InstallPin], name: String) -> Bool:
    for i in range(len(pins)):
        if pins[i].name == name:
            return True
    return False


def metapackage_members(release: LoadedRelease, meta_name: String) raises -> List[String]:
    """The members the built metapackage `meta_name` requires, read from
    its own `depends` and checked against release.json (file header), in
    `depends` order. RAISES naming what disagrees."""
    var who = String("metapackage '") + meta_name + String("'")
    var at = -1
    for m in range(len(release.members)):
        if release.members[m].has_conda and release.members[m].conda.name == meta_name:
            at = m
    if at < 0 or release.members[at].conda.kind != KIND_METAPACKAGE:
        raise Error(String("'") + meta_name + String("' is not a metapackage of the release set"))
    ref depends = release.members[at].conda.depends
    var names = List[String]()
    for d in range(len(depends)):
        ref req = depends[d]
        if req.startswith(String("__")):
            continue  # a virtual package: the platform guard
        var words = req.split(String(" "))
        if len(words) != 3 or not String(words[1]).startswith(String("==")):
            raise Error(
                who + String(" requires '") + req
                + String("', which is not `<member> ==<version> <build>`: kci cannot tell what it installs")
            )
        var name = String(words[0])
        var version = String(String(words[1])[byte = 2 :])
        var build = String(words[2])
        var pinned = False
        for e in range(len(release.recomputed.entries)):
            ref entry = release.recomputed.entries[e]
            if entry.name != name:
                continue
            pinned = True
            if entry.version != version or entry.build != build:
                raise Error(
                    who + String(" requires ") + name + String(" ") + version + String(" ") + build
                    + String(", but the release has ") + name + String(" ") + entry.version + String(" ")
                    + entry.build + String(": the solver would bring another build than the one validated")
                )
        if not pinned:
            raise Error(who + String(" requires '") + name + String("', which is not a member of the release set"))
        var library = False
        for m in range(len(release.members)):
            ref mem = release.members[m]
            if mem.has_conda and mem.conda.name == name and mem.conda.kind == KIND_LIBRARY:
                library = True
        if not library:
            raise Error(who + String(" requires '") + name + String("', which is not a library of the release set"))
        for k in range(len(names)):
            if names[k] == name:
                raise Error(who + String(" requires '") + name + String("' twice"))
        names.append(name^)
    if len(names) == 0:
        raise Error(
            who + String(" requires no member, so installing it would check nothing: a validation that checks")
            + String(" nothing is not a pass")
        )
    for m in range(len(release.members)):
        ref mem = release.members[m]
        if not mem.has_conda or mem.conda.kind != KIND_LIBRARY:
            continue
        var listed = False
        for k in range(len(names)):
            if names[k] == mem.conda.name:
                listed = True
        if not listed:
            raise Error(
                String("library '") + mem.conda.name + String("' of the release set is not required by ") + who
                + String(": installing it would not bring that library")
            )
    return names^


def with_members(release: LoadedRelease, pins: List[InstallPin]) raises -> List[InstallPin]:
    """`pins`, then every member of each metapackage among them that is not
    already a pin (file header). RAISES as `metapackage_members` does."""
    var out = pins.copy()
    for i in range(len(pins)):
        if pins[i].is_library:
            continue
        var members = metapackage_members(release, pins[i].name)
        for k in range(len(members)):
            if _has_pin(out, members[k]):
                continue
            var one = List[String]()
            one.append(members[k].copy())
            var got = install_pins(release, one)
            out.append(got[0].copy())
    return out^


def mojo_pin_of(release: LoadedRelease) raises -> String:
    """The `mojo_pin` every library of the set records; RAISES when there is
    no library, one has none, or two disagree."""
    var pin = String("")
    var seen = False
    for m in range(len(release.members)):
        ref mem = release.members[m]
        if not mem.has_conda or mem.conda.kind != KIND_LIBRARY:
            continue
        if mem.conda.mojo_pin.byte_length() == 0:
            raise Error(String("library '") + mem.conda.name + String("' records no mojo_pin"))
        if seen and mem.conda.mojo_pin != pin:
            raise Error(
                String("the libraries were built with two compilers: mojo_pin ") + pin + String(" and ")
                + mem.conda.mojo_pin + String(" ('") + mem.conda.name + String("')")
            )
        pin = mem.conda.mojo_pin.copy()
        seen = True
    if not seen:
        raise Error(String("the release set holds no library, so no mojo_pin names the compiler"))
    if not _shell_safe(pin):
        raise Error(String("mojo_pin '") + pin + String("' is not a version kci will write into a manifest"))
    return pin^
