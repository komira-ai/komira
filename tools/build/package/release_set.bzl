"""The stamped release path, built by any build that includes a
conda_release_set_check target (`buck2 build //...`, and the per-change
check's unit that holds it): a release set's libraries packaged with a fixed
TEST stamp, their `[release]` manifests given to `komira_pack conda-meta`, and
the metapackage read back.

A release builds `<lib>_conda[release]` with the stamp kci derives from git
(`-c komira.package_stamp=<N> ...`) and then runs `komira_pack conda-meta` over
those manifests (release/artifacts.textproto). A build without that `-c` has no
stamped `[release]`, so neither step runs before a release does. This rule runs
both, with a stamp that no release carries:

    load("@komira//tools/build/package:release_set.bzl", "conda_release_set_check")

    conda_release_set_check(
        name = "release_set_check",
        metapackage = "komira_all",
        libs = ["//src/komira_encoding:komira_encoding"],
        release_set = "release_set.txt",
    )

For each library it declares `<name>_<lib>_conda` with
conda_package_test_stamped (conda.bzl: the same rule as `<lib>_conda`, with
build number `TEST_STAMP`, source commit `TEST_COMMIT` and commit time
`TEST_TIMESTAMP_MS` given instead of read from the configuration). Then, as
build actions:

  * `komira_pack conda-meta --name <metapackage>` over each member's
    `[release]/manifest.json`. Its `--license`, `--summary` and `--home` are
    copied from release/artifacts.textproto's metapackage into this file and
    conda.bzl; the stamp check holds them equal to `release_set`, and
    src/kci_artifact's welded test holds `release_set` equal to the textproto.
    Its `--label` is this target's, not a release's;
  * a stamp check, naming what it fails on:
      - `release_set` names `metapackage` and, in order, the conda names of
        `libs` as its members, and the conda-meta arguments above;
      - every member's `[release]` directory and the metapackage's hold
        `<name>-<version>-TEST_BUILD.conda`, the manifest names that file and
        the version (the pinned compiler's);
      - the top level of each metadata.json (the metapackage's `members` rows
        removed first) carries `build` TEST_BUILD, `build_number` TEST_STAMP,
        `source_commit` TEST_COMMIT, `stamped` true and `timestamp_ms`
        TEST_TIMESTAMP_MS. TEST_BUILD is a literal (conda.bzl), not derived
        from TEST_COMMIT here;
      - the metapackage's metadata.json requires each member by name at that
        version and build string (conda-check checks the same requirements,
        but reports a missing one as a count, not by name);
  * a release order check: no member's metadata.json `depends` holds
    `"<name> ==<version> TEST_BUILD"` for a member `release_set` lists after
    it (a requirement at another version or build string is not one of this
    set's). The native package komira_native, which libraries require and
    which is listed after every library, is the one exception. The target's
    `order_tests` (release_order_test: this check over fixture
    metadata.json files) must pass first;
  * after the stamp check, `komira_pack conda-check --kind metapackage
    --require-stamped true` over the metapackage, with every member's manifest and the compiler pin: the
    `members` rows, the requirements, and that index, metadata and members
    agree.

The default output is the metapackage's directory (its `.conda`, manifest.json
and metadata.json), copied only after the three checks passed. Nothing is uploaded,
and no action uses the network.

A member's `[release]` exists only after its own `[release_check]` passed, so
that check runs too. What this does NOT cover: the macro conda_package's reading
of `-c komira.package_*` (these packages are given the test stamp); that a
member's requirement on another member is at the set's version and build string
(komira_pack writes it so; the order check reads only requirements that are);
and agreement across members beyond the stamp.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load(
    "@komira//tools/build/package:conda.bzl",
    "MOJO_COMPILER_VERSION",
    "PACKAGE_HOME",
    "PACKAGE_LICENSE",
    "TEST_BUILD",
    "TEST_COMMIT",
    "TEST_STAMP",
    "TEST_TIMESTAMP_MS",
    "conda_package_test_stamped",
)
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

# Copied from release/artifacts.textproto's metapackage `--summary`; the stamp
# check holds it equal to release_set.txt's.
_SUMMARY = "Every komira library of one release."

_STAMP_CHECK = """
BB="$1"; OUT="$2"; V="$3"; N="$4"; C="$5"; TS="$6"; B="$7"; META="$8"; MDIR="$9"; shift 9
SET="$1"; LIC="$2"; SUM="$3"; HOME_URL="$4"; shift 4
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch, as every busybox action here (defs.bzl `_PRELUDE`).
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/tmp" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; TMPDIR="$T/tmp"; HOME="$T/home"; export PATH TMPDIR HOME
unset LD_LIBRARY_PATH LD_PRELOAD || true
no() { echo "conda_release_set_check: $*" >&2; exit 1; }

# The release set file against what this target was given.
want=""; got_meta=""; got_lic=""; got_sum=""; got_home=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|"#"*) continue ;; esac
    k="${line%% *}"; v="${line#* }"
    case "$k" in
        metapackage) got_meta="$v" ;;
        member) want="$want $v" ;;
        license) got_lic="$v" ;;
        summary) got_sum="$v" ;;
        home) got_home="$v" ;;
        *) no "$SET: unknown key '$k'" ;;
    esac
done < "$SET"
[ "$got_meta" = "$META" ] || no "$SET names the metapackage '$got_meta', this target makes '$META'"
[ "$got_lic" = "$LIC" ] || no "$SET's license is '$got_lic', conda-meta is given '$LIC'"
[ "$got_sum" = "$SUM" ] || no "$SET's summary is '$got_sum', conda-meta is given '$SUM'"
[ "$got_home" = "$HOME_URL" ] || no "$SET's home is '$got_home', conda-meta is given '$HOME_URL'"

# The top level of a metadata.json: the metapackage's `members` rows (which
# carry `build` and `version` too) removed.
top() { sed 's/"members":\\[[^]]*\\],*//' "$1" > "$T/top.json"; }
# A key and its value in compact sorted JSON: followed by `,` or `}`.
has() { grep -qF -e "$1," -e "$1}" "$2"; }
stamped() { # <what> <name> <dir>
    f="$2-$V-$B.conda"
    [ -f "$3/$f" ] || no "$1 $2: [$(ls -A "$3" | tr '\\n' ' ')] holds no $f (version $V, build $B: the test stamp)"
    has "\\"file\\":\\"$f\\"" "$3/manifest.json" || no "$1 $2: manifest.json does not name $f: $(cat "$3/manifest.json")"
    has "\\"version\\":\\"$V\\"" "$3/manifest.json" || no "$1 $2: manifest.json is not version $V: $(cat "$3/manifest.json")"
    top "$3/metadata.json"
    for kv in "\\"build\\":\\"$B\\"" "\\"build_number\\":$N" "\\"source_commit\\":\\"$C\\"" '"stamped":true' "\\"timestamp_ms\\":$TS"; do
        has "$kv" "$T/top.json" || no "$1 $2: metadata.json does not carry $kv of the test stamp at its top level: $(cat "$3/metadata.json")"
    done
}
names=""
while [ "$#" -gt 0 ]; do
    stamped member "$1" "$2"
    names="$names $1"
    shift 2
done
[ "$names" = "$want" ] || no "libs are [$names ], $SET's members are [$want ]: the two lists of the release set differ"
stamped metapackage "$META" "$MDIR"
for m in $names; do
    grep -qF "\\"$m ==$V $B\\"" "$MDIR/metadata.json" ||
        no "metapackage $META does not require member $m at $V $B: $(cat "$MDIR/metadata.json")"
done
printf 'stamped %s %s:%s\\n' "$V" "$B" "$names" > "$OUT"
rm -rf "$T"
"""

# Release order (the module documentation): no member requires a member listed
# after it. A release builds the members in this order, each after the members
# it requires. Arguments: the busybox, the output, the release set file (named
# in the message only), the version, the build string, then `<name>
# <metadata.json>` per member in order. A requirement is `"<name> ==<V> <B>"`
# in metadata.json's `depends` (komira_pack). The one exception is the native
# package komira_native: libraries require it and it is listed after every
# library. release_order_test runs this script over fixtures.
_ORDER_CHECK = """
BB="$1"; OUT="$2"; SET="$3"; V="$4"; B="$5"; shift 5
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
unset LD_LIBRARY_PATH LD_PRELOAD || true
no() { echo "conda_release_set_check: $*" >&2; exit 1; }
names=""; metas=""
while [ "$#" -gt 0 ]; do
    names="$names $1"
    metas="$metas $2"
    shift 2
done
later="$names"
set -- $metas
for m in $names; do
    f="$1"; shift
    later="${later# $m}"
    for r in $later; do
        [ "$r" != komira_native ] || continue
        if grep -qF "\\"$r ==$V $B\\"" "$f"; then
            no "member $m requires $r, which $SET lists after it: list each member after the members it requires (here, in release/artifacts.textproto and in libs)"
        fi
    done
done
printf 'in order:%s\\n' "$names" > "$OUT"
rm -rf "$T"
"""

_COPY_DIR = '"$1" mkdir -p "$3"; "$1" cp -R "$2"/. "$3"/'

def _impl(ctx):
    if len(ctx.attrs.libs) != len(ctx.attrs.packages) or not ctx.attrs.libs:
        fail("{}: libs and packages are one list of members (the macro writes both), and not empty".format(ctx.label))
    pack = ctx.attrs._pack[RunInfo]
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    meta = ctx.attrs.metapackage
    members = []
    for lib, pkg in zip(ctx.attrs.libs, ctx.attrs.packages):
        name = lib[MojoInfo].conda_name
        if name == None:
            fail("{}: {} has no conda package".format(ctx.label, lib.label))
        members.append((name, pkg[DefaultInfo].sub_targets["release"][DefaultInfo].default_outputs[0]))
    manifests = [cmd_args("--member-manifest", cmd_args(d, format = "{}/manifest.json")) for _, d in members]

    raw = ctx.actions.declare_output("raw/" + meta, dir = True)
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-meta",
            "--name",
            meta,
            manifests,
            "--license",
            PACKAGE_LICENSE,
            "--summary",
            _SUMMARY,
            "--home",
            PACKAGE_HOME,
            "--extra-file",
            cmd_args(ctx.attrs._license_file, format = "info/licenses/LICENSE={}"),
            "--label",
            str(ctx.label.raw_target()),
            "--out-dir",
            raw.as_output(),
        ),
        category = "conda_meta",
        identifier = meta,
    )

    stamp_ok = ctx.actions.declare_output(ctx.label.name + ".stamped")
    ctx.actions.run(
        busybox_sh(
            bb,
            _STAMP_CHECK,
            stamp_ok.as_output(),
            MOJO_COMPILER_VERSION,
            TEST_STAMP,
            TEST_COMMIT,
            TEST_TIMESTAMP_MS,
            TEST_BUILD,
            meta,
            raw,
            ctx.attrs.release_set,
            PACKAGE_LICENSE,
            _SUMMARY,
            PACKAGE_HOME,
            [cmd_args(n, d) for n, d in members],
        ),
        category = "conda_release_stamp_check",
        identifier = meta,
    )

    in_order = ctx.actions.declare_output(ctx.label.name + ".in_order")
    ctx.actions.run(
        busybox_sh(
            bb,
            _ORDER_CHECK,
            in_order.as_output(),
            ctx.attrs.release_set,
            MOJO_COMPILER_VERSION,
            TEST_BUILD,
            [cmd_args(n, cmd_args(d, format = "{}/metadata.json")) for n, d in members],
        ),
        category = "conda_release_order_check",
        identifier = meta,
    )

    checked = ctx.actions.declare_output(ctx.label.name + ".checked")
    ctx.actions.run(
        cmd_args(
            pack,
            "conda-check",
            "--dir",
            raw,
            "--kind",
            "metapackage",
            "--name",
            meta,
            "--expect-subdir",
            "linux-64",
            "--mojo-pin",
            MOJO_COMPILER_VERSION,
            "--require-stamped",
            "true",
            manifests,
            "--out",
            checked.as_output(),
            # After the stamp check: a member left out is reported by name
            # (conda-check reports a count of requirements).
            hidden = [stamp_ok],
        ),
        category = "conda_check",
        identifier = meta,
    )

    out = ctx.actions.declare_output(meta, dir = True)
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _COPY_DIR, "sh", bb, raw, out.as_output(), hidden = [stamp_ok, in_order, checked] + [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.order_tests]),
        category = "conda_release_set_join",
        identifier = meta,
    )
    return [DefaultInfo(default_output = out)]

_conda_release_set_check = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep(providers = [MojoInfo])),
        "metapackage": attrs.string(),
        "order_tests": attrs.list(attrs.dep(), default = []),
        "packages": attrs.list(attrs.dep()),
        "release_set": attrs.source(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_license_file": attrs.source(default = "komira//:LICENSE"),
        "_pack": attrs.exec_dep(default = "komira//tools/build/package:komira_pack", providers = [RunInfo]),
    },
)

def _release_set_check(name, metapackage, libs, release_set, **kwargs):
    """See the module documentation."""
    packages = []
    for lib in libs:
        pkg = "{}_{}_conda".format(name, lib.split(":")[-1])
        conda_package_test_stamped(
            name = pkg,
            lib = lib,
            summary = "{} with the test stamp of {}; a build-time check only.".format(lib, name),
        )
        packages.append(":" + pkg)
    _conda_release_set_check(
        name = name,
        metapackage = metapackage,
        libs = libs,
        packages = packages,
        release_set = release_set,
        exec_compatible_with = LINUX_X86_64,
        **kwargs
    )

conda_release_set_check = declares_docs(_release_set_check)

_ORDER_TEST = """
BB="$1"; OUT="$2"; S="$3"; WANT="$4"; shift 4
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Not the order check's own scratch directory, which it removes.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_order_test" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira_order_test" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira_order_test" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
no() { echo "release_order_test: $*" >&2; exit 1; }
if "$BB" sh -euc "$S" sh "$BB" "$T/out" "$@" 2> "$T/err"; then
    [ -z "$WANT" ] || no "the order check passed, expected a refusal containing '$WANT'"
    [ ! -s "$T/err" ] || no "the order check passed with stderr: $(cat "$T/err")"
else
    [ -n "$WANT" ] || no "the order check refused, expected it to pass: $(cat "$T/err")"
    [ "$(wc -l < "$T/err")" -eq 1 ] || no "the order check refused with more than one line of stderr: $(cat "$T/err")"
    grep -qF "$WANT" "$T/err" || no "the order check refused without '$WANT': $(cat "$T/err")"
fi
echo ok > "$OUT"
rm -rf "$T"
"""

def _release_order_test_impl(ctx):
    if len(ctx.attrs.members) != len(ctx.attrs.metadata_files) or not ctx.attrs.members:
        fail("{}: members and metadata_files are one list, and not empty".format(ctx.label))
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        busybox_sh(
            bb,
            _ORDER_TEST,
            out.as_output(),
            _ORDER_CHECK,
            ctx.attrs.refuses,
            "release_set",
            ctx.attrs.version,
            ctx.attrs.build,
            [cmd_args(n, m) for n, m in zip(ctx.attrs.members, ctx.attrs.metadata_files)],
        ),
        category = "release_order_test",
    )
    return [DefaultInfo(default_output = out)]

_release_order_test = rule(
    impl = _release_order_test_impl,
    doc = "The release order check run over fixture metadata.json files (`metadata_files`, one per name in `members`, in order) at `version` and `build`: red unless it refuses with one line of stderr containing `refuses`, or, when `refuses` is empty, passes with no stderr.",
    attrs = {
        "build": attrs.string(),
        "members": attrs.list(attrs.string()),
        "metadata_files": attrs.list(attrs.source()),
        "refuses": attrs.string(default = ""),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _release_order_test_macro(**kwargs):
    _release_order_test(exec_compatible_with = LINUX_X86_64, **kwargs)

release_order_test = declares_docs(_release_order_test_macro)
