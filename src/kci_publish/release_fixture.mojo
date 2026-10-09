# =============================================================================
# src/kci_publish/release_fixture.mojo -- `ExampleRelease`: writes a coherent
#   release directory, the way a BUILD step leaves one. A TEST AID.
# =============================================================================
#
# The welded tests need many release directories that differ from a good one
# in exactly one way. This writes the good one, from values a test may edit
# first:
#
#   komira_alpha   library, no set-internal requirement
#   komira_beta    library, requires komira_alpha
#   komira         the metapackage of both
#
# all at `version` / `build` / `build_number` / `commit` (the shapes of the
# packer's `metadata.json`, the compiler-version form: build `h<8 hex>_<N>`,
# pins `<name> ==<version> <build>`), each member directory holding exactly
# `manifest.json`, `metadata.json` and the `.conda` file (whose bytes are a
# short text: nothing here opens the archive). `write` computes every sha256
# and size, then writes `release.json` from what `kci_release_set` recomputes
# over the written members, so it is exactly what a BUILD step would write.
#
# `set_meta(member, key, raw_json)` replaces one `metadata.json` key AFTER
# the derived values are filled in, so a test can make any one key wrong; a
# key it does not write (`doc_files`) is added.
#
# It also renders the matching artifacts file and `--release-version`
# text, and reads back the set hash `release.json` records.
#
# The release identity is `revision` (a full commit id) and `platform`
# (`linux-x86_64`); `release.json` (major 2) records them and who produced
# it (`gh-1`, attempt 1). `write(dir)` writes into `dir` itself, which is a
# platform's release directory (`<release-dir>/<platform>`);
# `write_example_inputs` lays out a whole `--release-dir` and the files beside
# it, and returns the PUBLISH request that publishes it.
#
# `EXAMPLE_CHANNELS` declares six channels on `.invalid` hosts, each at a
# namespaced location `https://<host>/example/<channel>` (PUBLIC and
# PRIVATE, API token and OIDC; the `example-oidc*` push identities name the
# environment `EXAMPLE_ENVIRONMENT`, and `gamma` / `prod` name environments
# `gamma` / `prod`). Requests are built for stage `EXAMPLE_STAGE`, which runs
# in `EXAMPLE_ENVIRONMENT`: a stage's name and its environment differ, as in
# a release machine. `example_channel_path` is a channel's path on the host;
# `example_targets` loads a written directory and resolves it against one of
# them.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs
from std.os.path import isdir

from komira_json import JsonValue, parse_json_value

from kci_artifact import parse_artifacts
from kci_api import RunIdentity, release_platform_dir
from kci_artifact_proto.artifact import Artifacts
from kci_pkg_upload import content_identity_of
from kci_release_channel import Channel, find_channel, parse_channels_file
from kci_release_set.member import ReleaseMember, verify_member
from .inputs import LoadedRelease, load_release
from .plan import PublishTarget, resolve_targets
from .request import PublishRequest
from kci_release_set.release_manifest import (
    RELEASE_MANIFEST_NAME,
    ReleaseIdentity,
    release_manifest_of,
    render_release_manifest,
)


def write_text_file(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


struct FixtureMember(Copyable, Movable):
    """One member of the example release. Layout: owned values only."""

    var name: String
    var kind: String
    var internal: List[String]
    var content: String

    def __init__(out self, var name: String, var kind: String, var content: String):
        self.name = name^
        self.kind = kind^
        self.internal = List[String]()
        self.content = content^


struct ExampleRelease(Copyable, Movable):
    """See the file header. Layout: owned values only. No pointer field."""

    var version: String
    var build_number: Int
    var commit: String
    var revision: String
    var platform: String
    var subdir: String
    var timestamp_ms: Int
    var members: List[FixtureMember]
    var _edit_member: List[String]
    var _edit_key: List[String]
    var _edit_raw: List[String]
    var omit_release_json: Bool

    def __init__(out self):
        self.version = String("1.0.0")
        self.build_number = 3
        self.commit = String("0123456789abcdef0123456789abcdef01234567")
        self.revision = String("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
        self.platform = String("linux-x86_64")
        self.subdir = String("linux-64")
        self.timestamp_ms = 1790000000000
        self.members = List[FixtureMember]()
        self._edit_member = List[String]()
        self._edit_key = List[String]()
        self._edit_raw = List[String]()
        self.omit_release_json = False
        self.members.append(FixtureMember(String("komira_alpha"), String("library"), String("alpha conda bytes")))
        var beta = FixtureMember(String("komira_beta"), String("library"), String("beta conda bytes"))
        beta.internal.append(String("komira_alpha"))
        self.members.append(beta^)
        self.members.append(FixtureMember(String("komira"), String("metapackage"), String("meta conda bytes")))

    def build(self) -> String:
        return String("h") + String(self.commit[byte=0:8]) + String("_") + String(self.build_number)

    def file_name(self, name: String) -> String:
        return name + String("-") + self.version + String("-") + self.build() + String(".conda")

    def sha256_of(self, name: String) -> String:
        for i in range(len(self.members)):
            if self.members[i].name == name:
                return content_identity_of(self.members[i].content.as_bytes()).sha256_hex
        return String("")

    def set_meta(mut self, var member: String, var key: String, var raw_json: String):
        """Replace `member`'s metadata `key` with the JSON text `raw_json`
        (applied last); a key the written metadata does not hold is added."""
        self._edit_member.append(member^)
        self._edit_key.append(key^)
        self._edit_raw.append(raw_json^)

    def _pin(self, name: String) -> String:
        return name + String(" ==") + self.version + String(" ") + self.build()

    def metadata_json(self, m: FixtureMember) raises -> String:
        var depends = JsonValue.empty_array()
        depends.push(JsonValue.from_string(String("__linux")))
        var doc = JsonValue.empty_object()
        if m.kind == String("metapackage"):
            var rows = JsonValue.empty_array()
            for i in range(len(self.members)):
                ref o = self.members[i]
                if o.kind != String("library"):
                    continue
                depends.push(JsonValue.from_string(self._pin(o.name)))
                var row = JsonValue.empty_object()
                row.set_member(String("build"), JsonValue.from_string(self.build()))
                row.set_member(String("name"), JsonValue.from_string(o.name.copy()))
                row.set_member(String("sha256"), JsonValue.from_string(self.sha256_of(o.name)))
                row.set_member(String("version"), JsonValue.from_string(self.version.copy()))
                rows.push(row^)
            doc.set_member(String("build"), JsonValue.from_string(self.build()))
            doc.set_member(String("build_number"), JsonValue.from_i64(Int64(self.build_number)))
            doc.set_member(String("depends"), depends^)
            doc.set_member(String("file_name"), JsonValue.from_string(self.file_name(m.name)))
            doc.set_member(String("kind"), JsonValue.from_string(String("metapackage")))
            doc.set_member(String("label"), JsonValue.from_string(String("komira//tools/build/package:komira_pack conda-meta")))
            doc.set_member(String("members"), rows^)
        else:
            depends.push(JsonValue.from_string(String("mojo-compiler ==") + self.version))
            for d in range(len(m.internal)):
                depends.push(JsonValue.from_string(self._pin(m.internal[d])))
            doc.set_member(String("build"), JsonValue.from_string(self.build()))
            doc.set_member(String("build_number"), JsonValue.from_i64(Int64(self.build_number)))
            doc.set_member(String("depends"), depends^)
            doc.set_member(String("file_name"), JsonValue.from_string(self.file_name(m.name)))
            doc.set_member(String("import_name"), JsonValue.from_string(m.name.copy()))
            doc.set_member(String("kind"), JsonValue.from_string(String("library")))
            doc.set_member(String("label"), JsonValue.from_string(String("komira//src/") + m.name + String(":") + m.name + String("_conda")))
            doc.set_member(String("mojo_pin"), JsonValue.from_string(self.version.copy()))
        doc.set_member(String("name"), JsonValue.from_string(m.name.copy()))
        if m.kind != String("metapackage"):
            doc.set_member(String("payload_path"), JsonValue.from_string(String("lib/mojo/") + m.name + String(".mojoc")))
            doc.set_member(String("payload_sha256"), JsonValue.from_string(content_identity_of(m.name.as_bytes()).sha256_hex))
        doc.set_member(String("format"), JsonValue.from_string(String("kci.conda_metadata")))
        doc.set_member(String("schema_version"), JsonValue.from_i64(1))
        doc.set_member(String("size"), JsonValue.from_i64(Int64(m.content.byte_length())))
        doc.set_member(String("source_commit"), JsonValue.from_string(self.commit.copy()))
        doc.set_member(String("stamped"), JsonValue.from_bool(True))
        doc.set_member(String("subdir"), JsonValue.from_string(self.subdir.copy()))
        doc.set_member(String("timestamp_ms"), JsonValue.from_i64(Int64(self.timestamp_ms)))
        doc.set_member(String("version"), JsonValue.from_string(self.version.copy()))
        var out = JsonValue.empty_object()
        for i in range(doc.num_members()):
            var k = doc.key_at(i)
            var replaced = False
            for e in range(len(self._edit_member)):
                if self._edit_member[e] == m.name and self._edit_key[e] == k:
                    out.set_member(k.copy(), parse_json_value(self._edit_raw[e]))
                    replaced = True
            if not replaced:
                out.set_member(k.copy(), doc.value_at(i))
        # a key the packer writes only sometimes (`doc_files`): added
        for e in range(len(self._edit_member)):
            if self._edit_member[e] == m.name and not doc.has(self._edit_key[e]):
                out.set_member(self._edit_key[e].copy(), parse_json_value(self._edit_raw[e]))
        return out.serialize() + String("\n")

    def manifest_json(self, m: FixtureMember) -> String:
        return (
            String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"CONDA","name":"')
            + m.name
            + String('","version":"')
            + self.version
            + String('","platform":"')
            + self.platform
            + String('","subdir":"')
            + self.subdir
            + String('","file":"')
            + self.file_name(m.name)
            + String('","sha256":"')
            + self.sha256_of(m.name)
            + String('","metadata":"metadata.json"}\n')
        )

    def write(self, dir: String) raises:
        """Write the release directory into `dir` (created), `release.json`
        last unless `omit_release_json`."""
        makedirs(dir, exist_ok=True)
        var members = List[ReleaseMember]()
        for i in range(len(self.members)):
            ref m = self.members[i]
            var d = dir + String("/") + m.name
            makedirs(d, exist_ok=True)
            write_text_file(d + String("/") + self.file_name(m.name), m.content)
            write_text_file(d + String("/manifest.json"), self.manifest_json(m))
            write_text_file(d + String("/metadata.json"), self.metadata_json(m))
        if self.omit_release_json:
            return
        for i in range(len(self.members)):
            members.append(verify_member(self.members[i].name, dir + String("/") + self.members[i].name))
        write_text_file(
            dir + String("/") + String(RELEASE_MANIFEST_NAME),
            render_release_manifest(
                release_manifest_of(
                    members, ReleaseIdentity(self.revision.copy(), self.platform.copy(), String("gh-1"), 1)
                )
            ),
        )

    def set_hash(self, dir: String) raises -> String:
        """The set hash `release.json` in `dir` records."""
        var doc = parse_json_value(open(dir + String("/") + String(RELEASE_MANIFEST_NAME), "r").read())
        return doc.get(String("set_hash")).as_string()

    def artifacts_text(self) -> String:
        var t = String(
            'schema_version: 1\nbuild_systems {\n  name: "buck2"\n  executable: "buck2"\n  args: "build"\n}\n'
        )
        for i in range(len(self.members)):
            t += (
                String('artifacts {\n  name: "')
                + self.members[i].name
                + String('"\n  build_system: "buck2"\n  args: "//src/')
                + self.members[i].name
                + String(':release"\n  args: "--out"\n  args: "{out_dir}"\n}\n')
            )
        return t^

    def release_version_text(self) -> String:
        return (
            String("version=")
            + self.version
            + String("\nbuild_number=")
            + String(self.build_number)
            + String("\nbuild=")
            + self.build()
            + String("\ncommit=")
            + self.commit
            + String("\nbuck_args=-c komira.package_stamp=")
            + String(self.build_number)
            + String("\n")
        )


comptime EXAMPLE_HOST: String = "conda.example.invalid"
comptime EXAMPLE_TOKEN_SECRET: String = "EXAMPLE_CONDA_TOKEN"

comptime EXAMPLE_STAGE: String = "publish-prod"
"""The stage the example requests are built for."""

comptime EXAMPLE_ENVIRONMENT: String = "prod"
"""The GitHub environment `EXAMPLE_STAGE` runs in, and the one the
`example-oidc*` push identities name."""

comptime EXAMPLE_CHANNELS: String = """schema_version: 1 channel {
  name: "example-stable"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/stable"
    push_identity: "publisher@example.invalid"
    credential { kind: API_TOKEN secret_name: "EXAMPLE_CONDA_TOKEN" }
  }
}
channel {
  name: "example-private"
  visibility: PRIVATE
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/private"
    push_identity: "publisher@example.invalid"
    credential { kind: API_TOKEN secret_name: "EXAMPLE_CONDA_TOKEN" }
  }
}
channel {
  name: "example-oidc"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/oidc"
    push_identity: "repo:example/release:environment:prod"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
channel {
  name: "example-oidc-private"
  visibility: PRIVATE
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/oidc-private"
    push_identity: "repo:example/release:environment:prod"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
channel {
  name: "gamma"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/gamma"
    push_identity: "repo:example/release:environment:gamma"
    break_glass_push_identity: "repo:example/release:environment:gamma-breakglass"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
channel {
  name: "prod"
  visibility: PUBLIC
  repository {
    artifact_type: CONDA
    location: "https://conda.example.invalid/example/prod"
    push_identity: "repo:example/release:environment:prod"
    credential { kind: OIDC_TRUSTED_PUBLISHING }
  }
}
"""


def example_channel(name: String) raises -> Channel:
    return find_channel(parse_channels_file(String(EXAMPLE_CHANNELS)), name)


def example_channel_path(name: String) raises -> String:
    """The path of channel `name` on `EXAMPLE_HOST` (`example/stable` for
    `example-stable`): what a `ScriptedChannel` for it serves."""
    var location = example_channel(name).repository_for(String("CONDA")).location
    var prefix = String("https://") + String(EXAMPLE_HOST) + String("/")
    if not location.startswith(prefix):
        raise Error(String("example channel '") + name + String("' is not on ") + String(EXAMPLE_HOST))  # cov: unreachable every EXAMPLE_CHANNELS location is on EXAMPLE_HOST
    return String(location[byte = prefix.byte_length() :])


def example_artifacts(r: ExampleRelease) raises -> Artifacts:
    return parse_artifacts(r.artifacts_text(), String("example.textproto"))


def example_loaded(r: ExampleRelease, dir: String) raises -> LoadedRelease:
    return load_release(example_artifacts(r), dir)


def example_targets(
    r: ExampleRelease, dir: String, channel: String = String("example-stable")
) raises -> List[PublishTarget]:
    var loaded = example_loaded(r, dir)
    return resolve_targets(example_channel(channel), loaded.members)


def write_example_inputs(
    r: ExampleRelease, root: String, channel: String, plan: Bool = False
) raises -> PublishRequest:
    """Write `r` under `<root>/release/<platform>/`, and beside it the
    artifacts, `EXAMPLE_CHANNELS` and the `--release-version` file; return
    the PUBLISH request for `channel` in stage `EXAMPLE_STAGE`, environment
    `EXAMPLE_ENVIRONMENT`."""
    makedirs(root, exist_ok=True)
    var dir = release_platform_dir(root + String("/release"), r.platform)
    r.write(dir)
    write_text_file(root + String("/artifacts.textproto"), r.artifacts_text())
    write_text_file(root + String("/channels.textproto"), String(EXAMPLE_CHANNELS))
    write_text_file(root + String("/rv.txt"), r.release_version_text())
    var req = PublishRequest(RunIdentity(String("gh-2"), 1))
    req.artifacts_file = root + String("/artifacts.textproto")
    req.release_dir = root + String("/release")
    req.platform = r.platform.copy()
    req.revision_id = r.revision.copy()
    req.stage = String(EXAMPLE_STAGE)
    req.environment = String(EXAMPLE_ENVIRONMENT)
    req.channels_file = root + String("/channels.textproto")
    req.channel = channel.copy()
    req.release_version_file = root + String("/rv.txt")
    req.plan = plan
    req.step_name = String("publish")
    return req^
