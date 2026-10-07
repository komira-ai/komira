#!/usr/bin/env bash
# conda.sh -- tests of the conda packages (tools/build/package/conda.bzl, and
# `komira_pack conda` / `conda-check` behind it), on //src/komira_encoding:komira_encoding_conda
# and the fixture libraries of tests//negative/conda.
#
# usage: tools/build/tests/functional/conda.sh [--no-uncached] [--no-install | --require-install]   (from anywhere; BUCK2 overrides;
#        KOMIRA_TEST_KEEP=1 keeps the scratch directory, with every log, after a pass)
#
#   shape      the .conda is read with tools that are not the writer's: unzip
#              (three stored members, in order), zstd (both streams valid), tar
#              (regular files, owner 0/0, no mtime), jq (sorted compact JSON); the
#              info/ files a consumer reads are all there; index.json has exactly
#              the expected keys (no `noarch`), linux-64, build number 0 and
#              build string h00000000_0, version the Mojo compiler version,
#              the run requirements in order (guard, exact mojo-compiler pin;
#              each dependency as `name ==V BUILD`); the pkg tar holds the
#              library's .mojoc, byte for byte, and the library's README at
#              share/doc/komira_encoding/README.md, byte-equal to
#              src/komira_encoding/README.md, and nothing else; info/paths.json
#              lists exactly those two, and metadata.json's doc_files names the
#              README with its sha256; the licence is the repository's. The
#              package is a directory: the .conda, `manifest.json` and
#              `metadata.json`. manifest.json is EXACTLY the artifact manifest
#              contract of kci (ten keys in a fixed order, compact, one
#              trailing newline: kci's format name and major first,
#              `platform` linux-x86_64, `file` the channel's file name,
#              `sha256` the file's, `metadata` the bare name `metadata.json`);
#              every other fact is in metadata.json, which names its own
#              format and major.
#   pin        the package version AND the compiler pin in the run requirements
#              are the version of the pinned compiler in the platform table
#              (tools/build/platforms/table.bzl), the one place it is stated.
#              conda-check refuses a package whose version is not the compiler
#              version it is given, and a package built for another compiler.
#   generated  no BUCK file declares a package: a NEW fixture library gets
#              `<name>_conda` from the mojo_library macro and no declaration
#              anywhere, builds, and passes its check; `conda = False` gets no
#              target at all; `conda_name` publishes under another name and a
#              dependent requires that name; a dependency is rendered into the
#              run requirements at its own version.
#   refusals   a library that cannot be packaged keeps a target that BUILDS (so
#              `buck2 build //...` stays green), holding a REFUSED file with the
#              reason, and its [release] fails naming it: no tests, native code,
#              a run-time shared library, a name that is not a conda name, a
#              dependency with no package (opted out, or itself refused). The
#              libraries still build.
#   packer     komira_pack run directly gives the same bytes as the rule; its
#              check refuses a different payload, name, subdir or dependency
#              list, a doc file it was not told of, a missing one, one that
#              differs by a byte, the README declared under another path,
#              a corrupt zip, an unstamped release, a manifest that is not
#              the contract (an extra key, no `metadata` or another one, another
#              key order, no newline, a wrong sha256), a metadata file that
#              disagrees, and a stray file in the directory.
#   stamp      the version is the compiler version and the release iteration is
#              the conda BUILD NUMBER N from the configuration, with the build
#              string h<8 hex of the commit>_<N>, so two builds of one version
#              differ in file name, build and sha256: the unstamped
#              build (number 0) is refused by [release_check] and has no [release]; a
#              stamp without its source commit is refused; a stamped one is
#              accepted, carries the stamp and commit in every place, and
#              re-runs no compile (only the packing actions); [release]
#              exists only then. Via komira_pack directly: a commit time that
#              is not positive is refused by the release check, a short commit
#              by the packer.
#              release_version.sh counts first-parent commits to the last
#              non-documentation commit, in a scratch repo, prints the compiler
#              version it reads from the platform table at that commit, N, the
#              build string and that commit, and refuses a shallow clone and a
#              pin whose asset name and URL name two versions.
#   copies     the built directory is copied before anything else is built, and
#              every later step reads the copy: under local execution a second
#              build of the same target with another configuration overwrites the
#              buck-out path.
#   uncached   two builds in two fresh daemons with --no-remote-cache, one isolation
#              directory, give the same sha256 (skipped with --no-uncached).
#   index      komira_pack conda-index writes a local channel from the package
#              directory: linux-64/repodata.json byte-equal to the package's own
#              info/index.json plus its sha256 and size as jq builds it, the
#              file beside it, an empty noarch index, nothing else; it refuses
#              no --package-manifest, a non-empty directory, a package given twice and
#              a manifest whose sha256 is not the file's, writing nothing.
#   install    a pixi project whose channel is the built file served from a
#              file:// directory (written by komira_pack conda-index) installs it
#              with the pinned compiler, and `mojo run` of a program importing
#              the library, with no -I, prints the right bytes, and the env
#              holds share/doc/komira_encoding/README.md byte-equal to the
#              source README; the same project
#              without the package cannot import it. Needs pixi, jq and network
#              (the compiler comes from the channel it is pinned to); otherwise SKIP,
#              or FAIL with --require-install (install_gate/install_gate.sh).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 2
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
uncached=1
install=1
require_install=0
for a in "$@"; do
    case "$a" in
        --no-uncached) uncached=0 ;;
        --no-install) install=0 ;;
        --require-install) require_install=1 ;;
        *) echo "conda.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
if [ "$install" = 0 ] && [ "$require_install" = 1 ]; then
    echo "conda.sh: --require-install and --no-install contradict each other" >&2
    exit 2
fi
. "$ROOT/tools/build/tests/functional/install_gate/install_gate.sh"
# The install case's gate runs before any build: its SKIP line is printed here,
# and with --require-install a case that cannot run ends the script here (exit 1).
install_gate conda "$install" "$require_install" https://conda.modular.com/max/linux-64/repodata.json
gate=$?
[ "$gate" != 2 ] || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_conda.XXXXXX")
fails=0
pass() { echo "PASS  conda $1"; }
fail() { echo "FAIL  conda $1"; fails=$((fails + 1)); }

for tool in unzip zstd tar jq sha256sum cmp git; do
    command -v "$tool" > /dev/null || { echo "FAIL  conda needs $tool on PATH"; exit 1; }
done

# The Mojo compiler version, read from the platform table the way the packages' own
# derivation reads it (their derivation is Starlark in tools/build/package/conda.bzl):
# the version is stated in the table's pin and nowhere else.
pin=$(sed -n 's/.*"mojo_compiler_\(.*\)_linux-64\.conda".*/\1/p' tools/build/platforms/table.bzl)
[ -n "$pin" ] && [ "$(printf '%s\n' "$pin" | wc -l)" = 1 ] || { echo "FAIL  conda cannot read the compiler pin from tools/build/platforms/table.bzl"; exit 1; }
B0=h00000000_0 # the unstamped build string
F0=komira_encoding-$pin-$B0.conda
# The library's README, which its package installs at $DOC.
README=$ROOT/src/komira_encoding/README.md
DOC=share/doc/komira_encoding/README.md

PKG=//src/komira_encoding:komira_encoding_conda
FX=tests//negative/conda
out_of() { # target -> its full output path
    "$BUCK2" build "$1" --materializations all --show-full-output 2>> "$W/build.log" | sed -n 's/^[^ ]* //p' | tail -n 1
}
red() { # name, required text, target [buck2 args...]: the build must fail with the text
    local name=$1 text=$2 target=$3
    shift 3
    if "$BUCK2" build "$target" "$@" > "$W/$name.log" 2>&1; then
        fail "$name: $target built, but it must fail"
    elif grep -qF -- "$text" "$W/$name.log"; then
        pass "$name"
    else
        fail "$name: failed without '$text' (see $W/$name.log)"
    fi
}
refused() { # name, required reason text, package target: it BUILDS, as a REFUSED directory with the reason
    local name=$1 text=$2 target=$3 d
    if ! d=$(out_of "$target") || [ -z "$d" ]; then
        fail "$name: $target does not build, but a refused package must (see $W/build.log)"
    elif [ "$(ls "$d")" != REFUSED ]; then
        fail "$name: $target holds [$(ls "$d" | tr '\n' ' ')], not only REFUSED"
    elif ! grep -qF -- "$text" "$d/REFUSED"; then
        fail "$name: its REFUSED says '$(cat "$d/REFUSED")', not '$text'"
    else
        red "${name}_release" "$text" "${target}[release]" -c komira.package_stamp=7 -c komira.package_commit=0123456789abcdef0123456789abcdef01234567 -c komira.package_timestamp_ms=86400000
        pass "$name: the target builds as a REFUSED directory with the reason"
    fi
}

# ---- shape ----------------------------------------------------------------
OUT=$(out_of "$PKG")
LIBPKG=$(out_of //src/komira_encoding:komira_encoding)
CHECK=$(out_of "${PKG}[check]")
if [ -z "$OUT" ] || [ -z "$LIBPKG" ] || [ -z "$CHECK" ]; then
    fail "shape: cannot build $PKG and its sub-targets (see $W/build.log)"
    echo "logs: $W"
    exit 1
fi
# Copies, taken now and used for the rest of the script. Under local execution
# the stamp section below builds the same target with another configuration and
# that materializes a different file at the very same buck-out path, so a path
# read once, early, names the wrong package by the time the install step runs.
K="$W/keep"
mkdir -p "$K/pkg"
cp -L "$OUT"/* "$K/pkg/" && cp -L "$CHECK" "$K/package.check" && cp -L "$LIBPKG" "$K/library.mojoc" || {
    fail "shape: cannot copy the built files into $K"
    echo "logs: $W"
    exit 1
}
chmod -R u+w "$K"
CONDA=$K/pkg/$F0 MANIFEST=$K/pkg/manifest.json METADATA=$K/pkg/metadata.json CHECK=$K/package.check LIBPKG=$K/library.mojoc
problems=""
p() { problems="$problems $1"; }
[ "$(ls "$K/pkg" | tr '\n' ' ')" = "$F0 manifest.json metadata.json " ] || p "directory:[$(ls "$K/pkg" | tr '\n' ' ')]"
S="$W/shape"
mkdir -p "$S"
unzip -q -o "$CONDA" -d "$S" || p unzip
names=$(unzip -Z1 "$CONDA" | tr '\n' ' ')
[ "$names" = "metadata.json pkg-${F0%.conda}.tar.zst info-${F0%.conda}.tar.zst " ] || p "members:[$names]"
[ "$(unzip -Zv "$CONDA" | grep -c 'none (stored)')" = 3 ] || p not-all-stored
[ "$(cat "$S/metadata.json")" = '{"conda_pkg_format_version":2}' ] || p metadata.json
zstd -t -q "$S"/pkg-*.tar.zst "$S"/info-*.tar.zst 2> /dev/null || p zstd-test
zstd -dc "$S"/info-*.tar.zst > "$S/info.tar" && zstd -dc "$S"/pkg-*.tar.zst > "$S/pkg.tar" || p zstd-decode
tar -xf "$S/info.tar" -C "$S" && tar -xf "$S/pkg.tar" -C "$S" || p untar
for t in info pkg; do
    # every member a regular file owned by 0/0 with no time (1970-01-01)
    TZ=UTC tar -tvf "$S/$t.tar" | awk '$1 != "-rw-r--r--" || $2 != "0/0" || $4 != "1970-01-01"' | grep -q . && p "$t-tar-members"
done
[ "$(tar -tf "$S/info.tar" | tr '\n' ' ')" = "info/about.json info/index.json info/licenses/LICENSE info/paths.json " ] || p "info-files:[$(tar -tf "$S/info.tar" | tr '\n' ' ')]"
[ "$(tar -tf "$S/pkg.tar" | tr '\n' ' ')" = "lib/mojo/komira_encoding.mojoc $DOC " ] || p "pkg-files:[$(tar -tf "$S/pkg.tar" | tr '\n' ' ')]"
cmp -s "$S/lib/mojo/komira_encoding.mojoc" "$LIBPKG" || p payload-differs-from-library
cmp -s "$S/$DOC" "$README" || p readme-differs-from-source
cmp -s "$S/info/licenses/LICENSE" "$ROOT/LICENSE" || p licence
for f in info/index.json info/paths.json info/about.json; do
    [ "$(jq -S -c . "$S/$f")" = "$(cat "$S/$f")" ] || p "$f-not-sorted-compact"
done
jq -e --arg v "$pin" --arg b "$B0" '(keys == ["arch","build","build_number","depends","license","name","platform","subdir","timestamp","version"])
    and .name == "komira_encoding" and .subdir == "linux-64" and .platform == "linux" and .arch == "x86_64"
    and .build == $b and .build_number == 0 and .version == $v and .license == "Apache-2.0"
    and (has("noarch") | not)
    and .depends == ["__linux", "mojo-compiler ==\($v)"]' "$S/info/index.json" > /dev/null || p index.json
want_sha=$(sha256sum "$S/lib/mojo/komira_encoding.mojoc" | cut -c1-64)
doc_sha=$(sha256sum "$README" | cut -c1-64)
jq -e --arg s "$want_sha" --arg d "$doc_sha" --arg p "$DOC" --argjson n "$(stat -L -c %s "$README")" '.paths_version == 1 and (.paths | length) == 2 and .paths[0]._path == "lib/mojo/komira_encoding.mojoc"
    and .paths[0].path_type == "hardlink" and .paths[0].sha256 == $s
    and .paths[1]._path == $p and .paths[1].path_type == "hardlink" and .paths[1].sha256 == $d
    and .paths[1].size_in_bytes == $n' "$S/info/paths.json" > /dev/null || p paths.json
[ "$(jq .paths[0].size_in_bytes "$S/info/paths.json")" = "$(stat -L -c %s "$LIBPKG")" ] || p paths-size
file_sha=$(sha256sum "$CONDA" | cut -c1-64)
# manifest.json: exactly kci's artifact manifest contract.
jq -e --arg s "$file_sha" --arg v "$pin" --arg f "$F0" '(keys_unsorted == ["format","schema_version","artifact_type","name","version","platform","subdir","file","sha256","metadata"])
    and .format == "kci.artifact_manifest" and .schema_version == 1
    and .artifact_type == "CONDA" and .name == "komira_encoding" and .version == $v and .platform == "linux-x86_64" and .subdir == "linux-64"
    and .file == $f and .sha256 == $s and .metadata == "metadata.json"' "$MANIFEST" > /dev/null || p manifest-contract
[ "$(jq -c . "$MANIFEST")" = "$(head -c -1 "$MANIFEST")" ] && [ "$(tail -c 1 "$MANIFEST" | od -An -c | tr -d ' ')" = '\n' ] || p manifest-not-compact-with-newline
# metadata.json: everything else.
jq -e --arg s "$file_sha" --arg p "$want_sha" --arg v "$pin" --arg b "$B0" --arg f "$F0" --argjson z "$(stat -L -c %s "$CONDA")" '.format == "kci.conda_metadata" and .schema_version == 1 and .kind == "library"
    and .size == $z and .payload_sha256 == $p and .file_name == $f and .payload_path == "lib/mojo/komira_encoding.mojoc"
    and .stamped == false and .source_commit == "" and .name == "komira_encoding" and .import_name == "komira_encoding"
    and .subdir == "linux-64" and .version == $v and .timestamp_ms == 0 and .build == $b and .build_number == 0
    and .mojo_pin == $v and .depends == ["__linux", "mojo-compiler ==\($v)"]
    and .label == "komira//src/komira_encoding:komira_encoding_conda"
    and .doc_files == [{"path": "share/doc/komira_encoding/README.md", "sha256": $d}]' --arg d "$doc_sha" "$METADATA" > /dev/null || p metadata
[ "$(jq -S -c . "$METADATA")" = "$(cat "$METADATA")" ] || p metadata-not-sorted-compact
[ "$(cat "$CHECK")" = ok ] || p check-marker
if [ -n "$problems" ]; then fail "shape:$problems (see $S)"; else
    pass "shape: $PKG is a directory of the .conda (three stored members, two valid zstd streams of owner-0 tars, linux-64, the library's .mojoc byte for byte, its README at $DOC byte-equal to the source and in paths.json and doc_files), the artifact manifest (exactly the ten contract keys, \`metadata\` naming metadata.json) and the metadata; sha256 $file_sha"
fi

# ---- packer ---------------------------------------------------------------
# komira_pack run directly on the client: the same inputs give the same bytes,
# and they are the bytes the rule's action wrote; conda-check refuses what is
# wrong with a package, so a green check is evidence.
PACK=$(out_of //tools/build/package:komira_pack)
SRCS=$(out_of //src/komira_encoding:komira_encoding[src])
LABEL=komira//src/komira_encoding:komira_encoding_conda
SUMMARY='The `komira_encoding` Mojo library of komira, as a conda package.'
pack() { # out-dir, payload [extra komira_pack args...]
    local o=$1 payload=$2
    shift 2
    "$PACK" conda --name komira_encoding --import-name komira_encoding\
        --stamp 0 --timestamp-ms 0 --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary "$SUMMARY" --home https://github.com/komira-ai/komira --payload "$payload" --sources "$SRCS" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "$LABEL" --doc-file "README.md=$README" --out-dir "$o" "$@"
}
packs() { # out-dir, stamp, timestamp-ms [extra komira_pack args...]: a stamped package
    local o=$1 st=$2 ts=$3
    shift 3
    "$PACK" conda --name komira_encoding --import-name komira_encoding\
        --stamp "$st" --timestamp-ms "$ts" --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary "s" --home https://github.com/komira-ai/komira --payload "$LIBPKG" --sources "$SRCS" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "$LABEL" --doc-file "README.md=$README" --out-dir "$o" "$@"
}
check() { # dir payload [extra args...]
    local d=$1 payload=$2
    shift 2
    "$PACK" conda-check --dir "$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$payload" --doc-file "README.md=$README" --out "$W/check.marker" "$@"
}
problems=""
pack "$W/pack1" "$LIBPKG" 2> "$W/pack1.err" || problems="$problems pack1-failed"
pack "$W/pack2" "$LIBPKG" 2> "$W/pack2.err" || problems="$problems pack2-failed"
if [ -z "$problems" ]; then
    cmp -s "$W/pack1/$F0" "$W/pack2/$F0" || problems="$problems two-runs-differ"
    cmp -s "$W/pack1/$F0" "$CONDA" || problems="$problems differs-from-the-rule's-package"
    cmp -s "$W/pack1/manifest.json" "$MANIFEST" || problems="$problems manifest-differs"
    cmp -s "$W/pack1/metadata.json" "$METADATA" || problems="$problems metadata-differs"
    check "$W/pack1" "$LIBPKG" 2> "$W/check_ok.err" || problems="$problems check-refused-a-good-package"
    # A package whose file name sorts AFTER metadata.json (komira_* sorts before it, rest_url after):
    # the check finds the .conda among the three files, never by its position in a sorted listing.
    "$PACK" conda --name rest_url --import-name komira_encoding --stamp 0 --timestamp-ms 0 --subdir linux-64 \
        --mojo-pin "$pin" --license Apache-2.0 --summary "$SUMMARY" --home https://github.com/komira-ai/komira \
        --payload "$LIBPKG" --sources "$SRCS" --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" \
        --label "$LABEL" --out-dir "$W/pack_late" 2> "$W/pack_late.err" || problems="$problems pack-late-failed"
    "$PACK" conda-check --dir "$W/pack_late" --kind library --name rest_url --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --out "$W/check_late.marker" 2> "$W/check_late.err" || problems="$problems check-refused-a-late-sorting-name"
    # One byte of the payload changed: a different package (only its pkg member and the
    # checksums over it), which the check refuses against the real payload and accepts against its own.
    cp "$LIBPKG" "$W/payload2.mojoc" && chmod u+w "$W/payload2.mojoc" && printf 'X' | dd of="$W/payload2.mojoc" bs=1 seek=100 conv=notrunc 2> /dev/null
    pack "$W/pack3" "$W/payload2.mojoc" 2> "$W/pack3.err" || problems="$problems pack3-failed"
    cmp -s "$W/pack1/$F0" "$W/pack3/$F0" && problems="$problems a-changed-payload-gave-the-same-package"
    check "$W/pack3" "$LIBPKG" 2> "$W/check_payload.err" && problems="$problems check-accepted-a-different-payload"
    grep -q 'the payload differs from the library' "$W/check_payload.err" || problems="$problems check-payload-text"
    check "$W/pack3" "$W/payload2.mojoc" 2> /dev/null || problems="$problems check-refused-its-own-payload"
    check "$W/pack1" "$LIBPKG" --require-stamped true 2> "$W/check_unstamped.err" && problems="$problems check-accepted-unstamped-as-release"
    grep -q 'never stamped' "$W/check_unstamped.err" || problems="$problems unstamped-text"
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_other --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --out "$W/check.marker" 2> "$W/check_name.err" && problems="$problems check-accepted-another-name"
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir osx-arm64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --out "$W/check.marker" 2> "$W/check_subdir.err" && problems="$problems check-accepted-another-subdir"
    # The caller states the dependencies; a package that requires others, or fewer, is refused.
    check "$W/pack1" "$LIBPKG" --dep komira_json 2> "$W/check_dep.err" && problems="$problems check-accepted-a-missing-dependency"
    grep -q 'index depends has' "$W/check_dep.err" || problems="$problems check-dep-text"
    # A package whose zip was edited by one byte is refused.
    cp -r "$W/pack1" "$W/pack4" && chmod -R u+w "$W/pack4" && printf 'Z' | dd of="$W/pack4/$F0" bs=1 seek=200 conv=notrunc 2> /dev/null
    check "$W/pack4" "$LIBPKG" 2> "$W/check_zip.err" && problems="$problems check-accepted-a-corrupt-zip"
    # The manifest must be the contract: each of these is refused.
    mutate() { # name, jq program or `raw:<text>` for the manifest, then the directory is checked
        local name=$1 prog=$2 d="$W/mut_$1"
        cp -r "$W/pack1" "$d" && chmod -R u+w "$d"
        case "$prog" in
            raw:*) printf '%s' "${prog#raw:}" > "$d/manifest.json" ;;
            meta:*) jq -S -c "${prog#meta:}" "$W/pack1/metadata.json" > "$d/metadata.json" ;;
            *) jq -c "$prog" "$W/pack1/manifest.json" > "$d/manifest.json" ;;
        esac
        if check "$d" "$LIBPKG" 2> "$W/mut_$name.err"; then problems="$problems check-accepted-$name"; fi
    }
    mutate manifest-extra-key '. + {label: "x"}'
    mutate manifest-missing-key 'del(.subdir)'
    mutate manifest-no-metadata 'del(.metadata)'
    mutate manifest-other-metadata '.metadata = "meta.json"'
    mutate manifest-other-order '{name, format, schema_version, artifact_type, version, platform, subdir, file, sha256, metadata}'
    mutate manifest-other-platform '.platform = "noarch"'
    mutate manifest-other-major '.schema_version = 2'
    mutate manifest-wrong-sha '.sha256 = ("0" * 64)'
    mutate manifest-wrong-type '.artifact_type = "conda"'
    mutate manifest-wrong-file '.file = "x.conda"'
    mutate manifest-no-newline "raw:$(jq -c . "$W/pack1/manifest.json")"
    mutate metadata-wrong-size 'meta:.size += 1'
    mutate metadata-wrong-kind 'meta:.kind = "metapackage"'
    mutate metadata-wrong-payload 'meta:.payload_sha256 = ("1" * 64)'
    mutate metadata-other-major 'meta:.schema_version = 2'
    grep -q 'exactly the ten keys' "$W/mut_manifest-extra-key.err" || problems="$problems extra-key-text"
    grep -q 'exactly the ten keys' "$W/mut_manifest-no-metadata.err" || problems="$problems no-metadata-text"
    grep -q 'is `meta.json`, must be `metadata.json`' "$W/mut_manifest-other-metadata.err" || problems="$problems other-metadata-text"
    cp -r "$W/pack1" "$W/pack5" && chmod -R u+w "$W/pack5" && echo stray > "$W/pack5/stray.txt"
    check "$W/pack5" "$LIBPKG" 2> "$W/check_stray.err" && problems="$problems check-accepted-a-stray-file"
    # The docs: the caller states them, and the check holds the package to exactly those, byte-equal.
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --out "$W/check.marker" 2> "$W/check_doc_undeclared.err" && problems="$problems check-accepted-an-undeclared-doc"
    grep -q 'must be exactly the .mojoc and the 0 declared doc file' "$W/check_doc_undeclared.err" || problems="$problems doc-undeclared-text"
    # Two docs: both installed, sorted by path, and a check told of both accepts it.
    pack "$W/pack_twodocs" "$LIBPKG" --doc-file "notes/NOTES.md=$ROOT/LICENSE" 2> /dev/null || problems="$problems pack-two-docs-failed"
    check "$W/pack_twodocs" "$LIBPKG" --doc-file "notes/NOTES.md=$ROOT/LICENSE" 2> "$W/check_twodocs.err" || problems="$problems check-refused-two-docs"
    jq -e '[.doc_files[].path] == ["share/doc/komira_encoding/README.md", "share/doc/komira_encoding/notes/NOTES.md"]' "$W/pack_twodocs/metadata.json" > /dev/null || problems="$problems two-docs-metadata"
    "$PACK" conda --name komira_encoding --import-name komira_encoding --stamp 0 --timestamp-ms 0 --subdir linux-64 \
        --mojo-pin "$pin" --license Apache-2.0 --summary "$SUMMARY" --home https://github.com/komira-ai/komira \
        --payload "$LIBPKG" --sources "$SRCS" --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" \
        --label "$LABEL" --out-dir "$W/pack_nodoc2" 2> /dev/null || problems="$problems pack-without-doc-failed"
    jq -e '.doc_files == []' "$W/pack_nodoc2/metadata.json" > /dev/null || problems="$problems no-doc-metadata-not-empty-list"
    check "$W/pack_nodoc2" "$LIBPKG" 2> "$W/check_doc_missing.err" && problems="$problems check-accepted-a-missing-doc"
    grep -q 'must be exactly the .mojoc and the 1 declared doc file' "$W/check_doc_missing.err" || problems="$problems doc-missing-text"
    cp "$README" "$W/readme_changed.md" && chmod u+w "$W/readme_changed.md" && printf 'X' | dd of="$W/readme_changed.md" bs=1 seek=10 conv=notrunc 2> /dev/null
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$W/readme_changed.md" --out "$W/check.marker" 2> "$W/check_doc_byte.err" && problems="$problems check-accepted-a-changed-doc"
    grep -q "$DOC differs from the declared doc file" "$W/check_doc_byte.err" || problems="$problems doc-byte-text"
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "readme.md=$README" --out "$W/check.marker" 2> "$W/check_doc_path.err" && problems="$problems check-accepted-a-doc-at-another-path"
    mutate metadata-doc-sha 'meta:.doc_files[0].sha256 = ("2" * 64)'
    mutate metadata-no-doc-files 'meta:del(.doc_files)'
    # The packer refuses a doc path that could leave share/doc/<name>/, or one given twice.
    for bad in "../README.md" "/README.md" "a//b.md" "./README.md" "" "a b.md"; do
        pack "$W/pack_bad_doc" "$LIBPKG" --doc-file "$bad=$README" 2> "$W/pack_bad_doc.err" && problems="$problems pack-accepted-doc-path-[$bad]"
    done
    pack "$W/pack_twice" "$LIBPKG" --doc-file "README.md=$README" 2> "$W/pack_twice.err" && problems="$problems pack-accepted-a-doc-twice"
    grep -q 'given twice' "$W/pack_twice.err" || problems="$problems doc-twice-text"
fi
# The release gate: what makes a package one an uploader may read.
if [ -z "$problems" ]; then
    C40=0123456789abcdef0123456789abcdef01234567
    packs "$W/rel_ok" 7 86400000 --commit "$C40" 2> "$W/rel_ok.err" || problems="$problems stamped-pack-failed"
    "$PACK" conda-check --dir "$W/rel_ok" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --require-stamped true --out "$W/check.marker" 2> "$W/rel_ok_check.err" || problems="$problems release-check-refused-a-good-release"
    B7=h01234567_7
    jq -e --arg c "$C40" --arg v "$pin" --arg b "$B7" '.stamped == true and .version == $v and .source_commit == $c and .timestamp_ms == 86400000 and .build == $b and .build_number == 7' "$W/rel_ok/metadata.json" > /dev/null || problems="$problems metadata-lacks-source-commit-or-build"
    jq -e --arg v "$pin" --arg f "komira_encoding-$pin-$B7.conda" '.version == $v and .file == $f' "$W/rel_ok/manifest.json" > /dev/null || problems="$problems manifest-version"
    [ -f "$W/rel_ok/komira_encoding-$pin-$B7.conda" ] || problems="$problems release-file-name"
    unzip -p "$W/rel_ok/komira_encoding-$pin-$B7.conda" 'info-*' | zstd -dc | tar -xO -f - info/index.json |
        jq -e --arg b "$B7" '.build == $b and .build_number == 7' > /dev/null || problems="$problems index-build"
    # Two builds of ONE version: another build number, or another commit at the same number, is another
    # build string and another file, and the version is unchanged (what the channel tells them apart by).
    packs "$W/rel_n8" 8 86400000 --commit "$C40" 2> /dev/null || problems="$problems n8-pack-failed"
    packs "$W/rel_c2" 7 86400000 --commit 89abcdef0123456789abcdef0123456789abcdef 2> /dev/null || problems="$problems c2-pack-failed"
    [ -f "$W/rel_n8/komira_encoding-$pin-h01234567_8.conda" ] && [ -f "$W/rel_c2/komira_encoding-$pin-h89abcdef_7.conda" ] || problems="$problems builds-not-named-by-number-and-commit"
    [ "$(jq -r .version "$W/rel_n8/manifest.json")" = "$pin" ] && [ "$(jq -r .version "$W/rel_c2/manifest.json")" = "$pin" ] || problems="$problems two-builds-differ-in-version"
    cmp -s "$W/rel_ok/komira_encoding-$pin-$B7.conda" "$W/rel_n8/komira_encoding-$pin-h01234567_8.conda" && problems="$problems two-builds-gave-the-same-bytes"
    for d in rel_n8 rel_c2; do
        "$PACK" conda-check --dir "$W/$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
            --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --require-stamped true --out "$W/check.marker" 2> /dev/null || problems="$problems $d-release-check-refused"
    done
    # The build string names the commit and the number the metadata states: each lie is refused.
    for case_ in 'build-number:.build_number = 8' 'commit:.source_commit = "89abcdef0123456789abcdef0123456789abcdef"' 'build:.build = "h01234567_8"' 'stamped:.stamped = false'; do
        d="$W/lie_${case_%%:*}"
        cp -r "$W/rel_ok" "$d" && chmod -R u+w "$d" && jq -S -c "${case_#*:}" "$W/rel_ok/metadata.json" > "$d/metadata.json"
        "$PACK" conda-check --dir "$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
            --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --require-stamped true --out "$W/check.marker" 2> "$d.err" && problems="$problems check-accepted-a-metadata-lie-${case_%%:*}"
    done
    for case_ in "rel_ts0:0:timestamp is not positive" "rel_tsneg:-5:timestamp is not positive"; do
        d=${case_%%:*} rest=${case_#*:} ts=${rest%%:*} text=${rest#*:}
        packs "$W/$d" 7 "$ts" --commit "$C40" 2> /dev/null || problems="$problems $d-pack-failed"
        "$PACK" conda-check --dir "$W/$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
            --mojo-pin "$pin" --payload "$LIBPKG" --doc-file "README.md=$README" --require-stamped true --out "$W/check.marker" 2> "$W/$d.err" && problems="$problems release-check-accepted-$d"
        grep -q "$text" "$W/$d.err" || problems="$problems $d-text"
    done
    packs "$W/rel_nocommit" 7 86400000 2> "$W/rel_nocommit.err" && problems="$problems stamped-pack-without-commit-accepted"
    grep -q 'must carry --commit' "$W/rel_nocommit.err" || problems="$problems no-commit-text"
    packs "$W/rel_shortcommit" 7 86400000 --commit abc123 2> "$W/rel_shortcommit.err" && problems="$problems short-commit-accepted"
    grep -q 'is not a full lowercase 40-digit hex commit id' "$W/rel_shortcommit.err" || problems="$problems short-commit-text"
fi
if [ -n "$problems" ]; then fail "packer:$problems (see $W)"; else
    pass "packer: komira_pack gives byte-identical packages from one payload (and the rule's), changes only the package for a changed payload; conda-check accepts it and refuses a different payload, name, subdir or dependency list, a corrupt zip, a manifest that is not the contract (extra key, missing key, no or another metadata, other order, wrong sha256, wrong type, wrong file, no newline), a metadata file that disagrees, a stray file, and an unstamped release; a release needs its source commit and a positive commit time"
fi

# ---- index ----------------------------------------------------------------
# komira_pack conda-index: a local channel from package directories, the same
# repodata.json a hand-built index has (the package's own info/index.json plus
# the file's sha256 and size, built here with unzip, zstd, tar and jq), the
# file copied beside it, an empty noarch index; and its refusals.
problems=""
I="$W/index"
"$PACK" conda-index --out-dir "$I" --package-manifest "$MANIFEST" > "$W/index.log" 2>&1 || problems="$problems conda-index-failed"
if [ -z "$problems" ]; then
    unzip -p "$CONDA" 'info-*' | zstd -dc | tar -xO -f - info/index.json > "$W/index_of_pkg.json"
    jq -S -c -n --slurpfile i "$W/index_of_pkg.json" --arg s "$file_sha" --arg f "$F0" --argjson z "$(stat -L -c %s "$CONDA")" \
        '{info: {subdir: "linux-64"}, packages: {}, "packages.conda": {($f): ($i[0] + {sha256: $s, size: $z})}, removed: [], repodata_version: 1}' > "$W/repodata_jq.json"
    [ "$(cat "$I/linux-64/repodata.json")" = "$(cat "$W/repodata_jq.json")" ] || problems="$problems repodata-differs-from-jq:[$(cat "$I/linux-64/repodata.json")]"
    [ "$(tail -c 1 "$I/linux-64/repodata.json" | od -An -c | tr -d ' ')" = '\n' ] || problems="$problems repodata-no-newline"
    [ "$(cat "$I/noarch/repodata.json")" = '{"info":{"subdir":"noarch"},"packages":{},"packages.conda":{},"removed":[],"repodata_version":1}' ] || problems="$problems noarch:[$(cat "$I/noarch/repodata.json")]"
    cmp -s "$I/linux-64/$F0" "$CONDA" || problems="$problems file-not-copied"
    [ "$(cd "$I" && find . -type f | sort | tr '\n' ' ')" = "./linux-64/$F0 ./linux-64/repodata.json ./noarch/repodata.json " ] || problems="$problems files:[$(cd "$I" && find . -type f | sort | tr '\n' ' ')]"
    grep -q 'linux-64/repodata.json lists 1 package(s)' "$W/index.log" || problems="$problems log-line"
fi
# refusals: each writes nothing new and names its reason
idx() { # name, required text, komira_pack conda-index args...
    local name=$1 text=$2
    shift 2
    if "$PACK" conda-index "$@" > "$W/idx_$name.log" 2>&1; then
        problems="$problems $name-accepted"
    elif ! grep -qF -- "$text" "$W/idx_$name.log"; then
        problems="$problems $name-text:[$(cat "$W/idx_$name.log")]"
    fi
}
idx no-manifest 'needs at least one --package-manifest' --out-dir "$W/idx_none"
idx not-empty 'is not empty' --out-dir "$I" --package-manifest "$MANIFEST"
idx twice 'is given twice' --out-dir "$W/idx_twice" --package-manifest "$MANIFEST" --package-manifest "$MANIFEST"
mkdir -p "$W/idx_badsha"
cp "$CONDA" "$METADATA" "$W/idx_badsha/"
sed "s/$file_sha/$(printf '%s' "$file_sha" | tr '0-9a-f' '1-9a-f0')/" "$MANIFEST" > "$W/idx_badsha/manifest.json"
idx bad-sha 'the sha256 of the file the manifest names' --out-dir "$W/idx_badsha_out" --package-manifest "$W/idx_badsha/manifest.json"
[ -e "$W/idx_none" ] || [ -e "$W/idx_twice" ] || [ -e "$W/idx_badsha_out" ] && problems="$problems a-refusal-wrote-a-directory"
if [ -n "$problems" ]; then fail "index:$problems (see $W)"; else
    pass "index: komira_pack conda-index writes the local channel $I: linux-64/repodata.json byte-equal to the package's own info/index.json plus its sha256 and size (as jq builds it), the file beside it byte for byte, an empty noarch index, and nothing else; it refuses no --package-manifest, a directory that is not empty, the same package twice and a manifest whose sha256 is not the file's, writing nothing"
fi

# ---- pin --------------------------------------------------------------------
# The version of every package IS the pinned compiler's version, and so is the
# compiler requirement. It is stated once (the platform table's pin, which names it
# in its asset name and in its URL: the two must agree) and derived everywhere else.
problems=""
url_pin=$(sed -n 's#.*/linux-64/mojo-compiler-\(.*\)-release\.conda".*#\1#p' tools/build/platforms/table.bzl)
[ "$url_pin" = "$pin" ] || problems="$problems table-asset-name-and-url-disagree:[$pin|$url_pin]"
grep -qE '^MOJO_COMPILER_VERSION = _compiler_version\(\)$' tools/build/package/conda.bzl || problems="$problems conda.bzl-does-not-derive-the-version"
grep -qE '(VERSION|PIN) = "[0-9]' tools/build/package/conda.bzl && problems="$problems conda.bzl-states-a-version"
grep -qE 'package = ":mojo_compiler_[0-9]' tools/build/toolchains/BUCK && problems="$problems toolchains-BUCK-states-a-version"
[ "$(jq -r '.version' "$S/info/index.json")" = "$pin" ] && [ "$(jq -r '.depends[1]' "$S/info/index.json")" = "mojo-compiler ==$pin" ] ||
    problems="$problems package-version-or-compiler-requirement-is-not-the-pin"
# Version skew: a package built for another compiler (version 9.9.9) is refused when
# checked against the pinned one, and the good package against another pin.
"$PACK" conda --name komira_encoding --import-name komira_encoding --stamp 0 --timestamp-ms 0 --subdir linux-64 --mojo-pin 9.9.9 \
    --license Apache-2.0 --summary s --home https://github.com/komira-ai/komira --payload "$LIBPKG" --sources "$SRCS" \
    --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "$LABEL" --out-dir "$W/skew" 2> "$W/skew.err" || problems="$problems skew-pack-failed"
[ -f "$W/skew/komira_encoding-9.9.9-$B0.conda" ] || problems="$problems skew-package-not-named-by-its-version"
check "$W/skew" "$LIBPKG" 2> "$W/skew_check.err" && problems="$problems check-accepted-a-package-for-another-compiler"
grep -q 'must be the Mojo compiler version' "$W/skew_check.err" || problems="$problems skew-text:[$(head -c 200 "$W/skew_check.err")]"
"$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
    --mojo-pin 9.9.9 --payload "$LIBPKG" --out "$W/check.marker" 2> "$W/skew2.err" && problems="$problems check-accepted-the-package-against-another-pin"
if [ -n "$problems" ]; then fail "pin:$problems (see $W)"; else
    pass "pin: the packages' version and their compiler requirement are both $pin, the version of the pinned compiler (stated once, in the platform table: no other file states it; its asset name and URL agree); conda-check refuses a package for another compiler version (9.9.9) and the right package against another pin"
fi

# ---- generated: no declaration anywhere -------------------------------------
# A library gets its package from the mojo_library macro. No BUCK file of this
# repository declares one by hand, and a new fixture library needs nothing.
problems=""
hand=$(git grep -lE '^[[:space:]]*conda_package\(' -- '*BUCK' || true)
[ -z "$hand" ] || problems="$problems a-BUCK-file-declares-a-package-by-hand:[$hand]"
d=$(out_of "$FX:fx_plain_conda") || problems="$problems fx_plain_conda-does-not-build"
if [ -n "$d" ] && [ -f "$d/manifest.json" ]; then
    jq -e --arg v "$pin" --arg b "$B0" '.name == "fx_plain" and .version == $v and .file == "fx_plain-\($v)-\($b).conda"' "$d/manifest.json" > /dev/null || problems="$problems fx_plain-manifest"
    jq -e --arg v "$pin" '.depends == ["__linux", "mojo-compiler ==\($v)"] and .import_name == "fx_plain" and .payload_path == "lib/mojo/fx_plain.mojoc"' "$d/metadata.json" > /dev/null || problems="$problems fx_plain-metadata"
    "$BUCK2" build "$FX:fx_plain_conda[check]" > "$W/fx_plain_check.log" 2>&1 || problems="$problems fx_plain-check-red"
fi
# a dependency is rendered at its own version, by its published name
d=$(out_of "$FX:fx_user_conda")
jq -e --arg v "$pin" --arg b "$B0" '.depends == ["__linux", "mojo-compiler ==\($v)", "fx_plain ==\($v) \($b)"]' "$d/metadata.json" > /dev/null 2>&1 || problems="$problems fx_user-requirement"
# conda_name: published under another name; the import name is unchanged; a dependent requires the published name
d=$(out_of "$FX:fx_renamed_conda")
if [ -f "$d/fx_published-$pin-$B0.conda" ]; then
    jq -e --arg v "$pin" --arg b "$B0" '.name == "fx_published" and .file == "fx_published-\($v)-\($b).conda"' "$d/manifest.json" > /dev/null || problems="$problems fx_renamed-manifest"
    jq -e '.import_name == "fx_renamed" and .payload_path == "lib/mojo/fx_renamed.mojoc"' "$d/metadata.json" > /dev/null || problems="$problems fx_renamed-payload-path"
else
    problems="$problems fx_renamed-file:[$(ls "$d" | tr '\n' ' ')]"
fi
d=$(out_of "$FX:fx_renamed_user_conda")
jq -e --arg v "$pin" --arg b "$B0" '.depends == ["__linux", "mojo-compiler ==\($v)", "fx_published ==\($v) \($b)"]' "$d/metadata.json" > /dev/null 2>&1 || problems="$problems fx_renamed_user-requirement"
# conda = False: no package target at all
if "$BUCK2" uquery "$FX:fx_optout_conda" > "$W/optout_q.log" 2>&1; then problems="$problems opted-out-library-has-a-package-target"; fi
grep -qiE 'unknown target|does not exist|not found|no such' "$W/optout_q.log" || problems="$problems opt-out-query-text:[$(head -c 200 "$W/optout_q.log")]"
# and the listing helper prints the packages, not the opted-out library
listing=$(tools/build/package/list_conda_targets.sh "$FX:" 2> "$W/list.err")
for t in fx_plain_conda fx_user_conda fx_renamed_conda fx_notests_conda fx_dlopen_conda; do
    printf '%s\n' "$listing" | grep -qF "$t" || problems="$problems list-lacks-$t"
done
printf '%s\n' "$listing" | grep -qF "fx_optout_conda" && problems="$problems list-has-the-opted-out-library"
if [ -n "$problems" ]; then fail "generated:$problems (see $W)"; else
    pass "generated: no BUCK file declares a package; a new fixture library gets fx_plain_conda from the macro, builds and passes its check; a dependency is required by its published name at its own version; conda_name publishes fx_renamed as fx_published (payload still lib/mojo/fx_renamed.mojoc); conda = False has no target; list_conda_targets.sh lists the packages"
fi

# ---- refusals: a target that builds, and a release that does not ------------
refused refuse_no_tests "has no tests, so its package would not be gated by any" "$FX:fx_notests_conda"
refused refuse_dlopen "opens a shared library at run time (OwnedDLHandle)" "$FX:fx_dlopen_conda"
refused refuse_bad_name "is not a conda name" "$FX:fx_badname_conda"
refused refuse_native "links native code" komira//tools/build/examples/cshim:cadd_conda
refused refuse_dep_opted_out "which has no conda package (\`conda = False\`" "$FX:fx_optout_user_conda"
refused refuse_dep_refused "it depends on" "$FX:fx_notests_user_conda"
# the libraries themselves still build
if "$BUCK2" build "$FX:fx_notests" "$FX:fx_dlopen" "$FX:fx_badname" "$FX:fx_optout" "$FX:fx_optout_user" "$FX:fx_notests_user" komira//tools/build/examples/cshim:cadd > "$W/libs_build.log" 2>&1; then
    pass "libraries: every library a package was refused for still builds"
else
    fail "libraries: a library with a refused package does not build (see $W/libs_build.log)"
fi
# Building every package of the fixtures at once is green: a refusal is data.
if "$BUCK2" build "$FX:" > "$W/fx_all.log" 2>&1; then
    pass "refusals: \`buck2 build $FX:\` is green with six refused packages in it"
else
    fail "refusals: building every fixture target failed (see $W/fx_all.log)"
fi

# ---- stamp ------------------------------------------------------------------
red release_refuses_unstamped "was never stamped" "${PKG}[release_check]"
red release_has_no_unstamped_file "was never stamped" "${PKG}[release]"
red release_refuses_stamp_without_commit "must carry --commit" "${PKG}[release]" -c komira.package_stamp=9 -c komira.package_timestamp_ms=86400000
# A stamp no earlier run used, so the packing actions execute and the check
# below sees them (a cached run would list nothing, which proves nothing).
N_STAMP=$((100000 + RANDOM))
C_STAMP=89abcdef0123456789abcdef0123456789abcdef
STAMP="-c komira.package_stamp=$N_STAMP -c komira.package_commit=$C_STAMP -c komira.package_timestamp_ms=86400000"
# shellcheck disable=SC2086 # STAMP is a list of words
if "$BUCK2" build $STAMP "${PKG}[release]" > "$W/stamp_check.log" 2>&1; then
    # No compile re-ran for a new stamp: the executed actions are packing, and only that.
    "$BUCK2" log what-ran --skip-cache-hits > "$W/stamp_whatran.txt" 2>&1
    if grep -q 'conda_pack' "$W/stamp_whatran.txt" && ! grep -qE 'mojo_(precompile|build|gated)' "$W/stamp_whatran.txt"; then
        # shellcheck disable=SC2086
        s_dir=$("$BUCK2" build $STAMP "${PKG}[release]" --materializations all --show-full-output 2> "$W/stamp_manifest.log" | sed -n 's/^[^ ]* //p' | tail -n 1)
        s_manifest=$s_dir/manifest.json s_meta=$s_dir/metadata.json
        B_STAMP=h89abcdef_$N_STAMP
        if jq -e --arg v "$pin" --arg b "$B_STAMP" '.version == $v and .file == "komira_encoding-\($v)-\($b).conda"' "$s_manifest" > /dev/null &&
            jq -e --arg v "$pin" --arg b "$B_STAMP" --arg c "$C_STAMP" --argjson n "$N_STAMP" '.version == $v and .build == $b and .build_number == $n and .stamped == true and .source_commit == $c and .timestamp_ms == 86400000' "$s_meta" > /dev/null &&
            [ "$(jq -r .sha256 "$s_manifest")" = "$(sha256sum < "$s_dir/$(jq -r .file "$s_manifest")" | cut -c1-64)" ]; then
            pass "stamp: -c komira.package_stamp=$N_STAMP gives version $pin, build number $N_STAMP and build string $B_STAMP ([release] green: manifest with the file name and sha256 of the file, metadata with the build number, build string and source commit) and the new stamp re-ran only the packing actions, no compile"
        else
            fail "stamp: the stamped package is not version $pin build number $N_STAMP (see $W/stamp_manifest.log)"
        fi
    else
        fail "stamp: a new stamp re-ran a Mojo action, or no packing action ran (see $W/stamp_whatran.txt)"
    fi
else
    fail "stamp: a stamped build is not accepted by [release] (see $W/stamp_check.log)"
fi

R="$W/repo"
mkdir -p "$R/src/x" "$R/docs" "$R/tools/build/package" "$R/tools/build/platforms"
cp tools/build/package/release_version.sh "$R/tools/build/package/"
# the pin, as the platform table states it (the aarch64 row names another file and is not read)
table() { # version in the asset name, version in the URL
    printf '    "mojo_compiler": pin(\n        "mojo_compiler_%s_linux-64.conda",\n        "https://example.invalid/max/linux-64/mojo-compiler-%s-release.conda",\n        "sha",\n    ),\n    "mojo_compiler": pin("mojo_compiler_%s_linux-aarch64.conda", "https://example.invalid/linux-aarch64/mojo-compiler-%s-release.conda", "sha"),\n' "$1" "$2" "$1" "$1" > "$R/tools/build/platforms/table.bzl"
}
table 7.3.1 7.3.1
echo a > "$R/src/x/a.mojo"
g() { GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    git -C "$R" "$@"; }
commit() { # message, epoch
    g add -A && GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" g commit -q -m "$1"
}
g init -q -b main && commit one 100000100 &&
    echo d > "$R/docs/a.md" && commit docs-only 100000200 &&
    echo b > "$R/src/x/b.mojo" && commit src 100000300 &&
    echo r > "$R/src/x/README.md" && mkdir -p "$R/.github" && echo w > "$R/.github/w.yml" && commit md-and-github-only 100000400 &&
    table 7.4.0 7.4.0 && commit compiler-bump 100000500
v() { sh "$R/tools/build/package/release_version.sh" "$@" 2>&1; }
want() { # version, N, commit, ms
    printf 'version=%s\nbuild_number=%s\nbuild=h%s_%s\ncommit=%s\nbuck_args=-c komira.package_stamp=%s -c komira.package_commit=%s -c komira.package_timestamp_ms=%s' "$1" "$2" "$(printf %s "$3" | cut -c1-8)" "$2" "$3" "$2" "$3" "$4"
}
problems=""
c1=$(g rev-parse HEAD~4) c3=$(g rev-parse HEAD~2) c5=$(g rev-parse HEAD)
[ "$(v HEAD~3)" = "$(want 7.3.1 1 "$c1" 100000100000)" ] || problems="$problems docs-only-commit:[$(v HEAD~3 | tr '\n' ' ')]"
[ "$(v HEAD~2)" = "$(want 7.3.1 3 "$c3" 100000300000)" ] || problems="$problems source-commit:[$(v HEAD~2 | tr '\n' ' ')]"
[ "$(v HEAD~1)" = "$(v HEAD~2)" ] || problems="$problems documentation-commit-changed-the-version"
# a compiler bump is a commit of the closure: its own version (the new pin) and the next build number
[ "$(v HEAD)" = "$(want 7.4.0 5 "$c5" 100000500000)" ] || problems="$problems compiler-bump:[$(v HEAD | tr '\n' ' ')]"
# a pin whose asset name and URL name two versions, or no pin at all, is refused
table 7.5.0 7.6.0 && commit disagreeing-pin 100000600
out=$(v HEAD) && problems="$problems disagreeing-pin-accepted"
printf '%s' "$out" | grep -q 'disagrees with itself' || problems="$problems disagreeing-pin-text:[$out]"
printf 'nothing\n' > "$R/tools/build/platforms/table.bzl" && commit no-pin 100000700
out=$(v HEAD) && problems="$problems missing-pin-accepted"
printf '%s' "$out" | grep -q 'cannot read the pinned compiler version' || problems="$problems missing-pin-text:[$out]"
git clone -q --depth 1 "file://$R" "$W/shallow" 2> /dev/null && cp -r "$R/tools" "$W/shallow/" &&
    sh "$W/shallow/tools/build/package/release_version.sh" > "$W/shallow.out" 2>&1 && problems="$problems shallow-clone-accepted"
grep -q 'shallow clone' "$W/shallow.out" || problems="$problems shallow-refusal-text"
# and on this repository the script's version is the version the packages carry
[ "$(sh tools/build/package/release_version.sh HEAD | sed -n 's/^version=//p')" = "$pin" ] || problems="$problems this-repository-version-is-not-the-pin"
[ -z "$problems" ] && pass "stamp: release_version.sh gives the pinned compiler version it reads from the platform table at the closure commit (a bump re-versions), build number N = the count to the last non-documentation commit, the build string h<8 hex>_<N>, that commit and its timestamp, ignores docs/, *.md and .github/, refuses a shallow clone, a pin whose asset name and URL disagree and a missing pin; on this repository it is $pin" ||
    fail "stamp: release_version.sh:$problems"

# ---- uncached ---------------------------------------------------------------
# Two builds in two fresh daemons with --no-remote-cache, one after the other
# in ONE isolation directory. Not two directories, as bundle.sh uses: a `.mojoc`
# records the path of the sources it was compiled from
# (buck-out/<isolation dir>/art/...), so the same library built under two
# isolation directory names is two different files that differ only in that
# name. A release builds under the default directory, always the same.
if [ "$uncached" = 1 ]; then
    problems=""
    for n in 1 2; do
        timeout 2400 "$BUCK2" --isolation-dir komira_tests_conda build --no-remote-cache "$PKG" --materializations all --show-full-output \
            > "$W/uncached_$n.out" 2> "$W/uncached_$n.log"
        rc=$?
        "$BUCK2" --isolation-dir komira_tests_conda kill > /dev/null 2>&1
        if [ "$rc" != 0 ]; then
            problems="$problems build-$n-failed"
        else
            f=$(sed -n 's/^[^ ]* //p' "$W/uncached_$n.out" | tail -n 1)
            cp -L "$f"/*.conda "$W/uncached_$n.conda"
            sha256sum < "$W/uncached_$n.conda" | cut -c1-64 > "$W/sha_$n.txt"
            if [ "${KOMIRA_CHECKS_MODE:-remote}" = local ]; then ran='Commands: [0-9]+ \(cached: 0, remote: 0, local: [1-9]'; else ran='Commands: [0-9]+ \(cached: 0, remote: [1-9]'; fi
            grep -qE "$ran" "$W/uncached_$n.log" || problems="$problems build-$n-did-not-execute"
        fi
    done
    if [ -z "$problems" ] && [ "$(cat "$W/sha_1.txt")" != "$(cat "$W/sha_2.txt")" ]; then
        problems=" differ: $(cat "$W/sha_1.txt") $(cat "$W/sha_2.txt")"
    fi
    if [ -n "$problems" ]; then fail "uncached:$problems (see $W)"; else
        pass "uncached: two uncached builds in two fresh daemons give $PKG sha256 $(cat "$W/sha_1.txt") ($(grep -oE 'Commands: [0-9]+' "$W/uncached_1.log" | head -n 1) actions each, none cached)"
    fi
else
    echo "SKIP  conda uncached (--no-uncached)"
fi

# ---- install (its gate ran above, before any build) ---------------------
if [ "$gate" = 0 ]; then
    problems=""
    # The channel is the one komira_pack conda-index wrote (section index).
    C="$W/channel"
    mkdir -p "$W/with" "$W/without"
    "$PACK" conda-index --out-dir "$C" --package-manifest "$MANIFEST" > "$W/channel.log" 2>&1 || problems="$problems channel-not-indexed"
    cat > "$W/hello.mojo" << 'EOF'
from komira_encoding import base64_encode, hex_encode


def main():
    var data = List[UInt8]()
    data.append(0xDE)
    data.append(0xAD)
    data.append(0xBE)
    data.append(0xEF)
    print(hex_encode(data))
    print(base64_encode(data))
EOF
    for variant in with without; do
        {
            printf '[workspace]\nname = "komira-conda-test"\nchannels = ["file://%s", "https://conda.modular.com/max", "conda-forge"]\nplatforms = ["linux-64"]\n\n[dependencies]\n' "$C"
            if [ "$variant" = with ]; then printf 'komira_encoding = "==%s"\n' "$pin"; else printf 'mojo-compiler = "==%s"\n' "$pin"; fi
        } > "$W/$variant/pixi.toml"
        cp "$W/hello.mojo" "$W/$variant/hello.mojo"
    done
    export PIXI_CACHE_DIR="$W/pixi_cache" PIXI_HOME="$W/pixi_home"
    pixi install --manifest-path "$W/with/pixi.toml" > "$W/install_with.log" 2>&1 || problems="$problems install-failed"
    if [ -z "$problems" ]; then
        [ -f "$W/with/.pixi/envs/default/lib/mojo/komira_encoding.mojoc" ] || problems="$problems payload-not-installed-at-lib/mojo"
        cmp -s "$W/with/.pixi/envs/default/lib/mojo/komira_encoding.mojoc" "$LIBPKG" || problems="$problems installed-payload-differs"
        cmp -s "$W/with/.pixi/envs/default/$DOC" "$README" || problems="$problems installed-readme-missing-or-differs"
        grep -qF "mojo-compiler" "$W/with/pixi.lock" && grep -q "$F0" "$W/with/pixi.lock" || problems="$problems lock-lacks-the-packages"
        got=$(cd "$W/with" && pixi run --manifest-path "$W/with/pixi.toml" mojo run hello.mojo 2> "$W/run_with.err")
        [ "$got" = "$(printf 'deadbeef\n3q2+7w==')" ] || problems="$problems program-output:[$got]"
    fi
    pixi install --manifest-path "$W/without/pixi.toml" > "$W/install_without.log" 2>&1 || problems="$problems control-install-failed"
    if (cd "$W/without" && pixi run --manifest-path "$W/without/pixi.toml" mojo run hello.mojo > "$W/run_without.out" 2>&1); then
        problems="$problems control-imported-without-the-package"
    elif ! grep -qF "komira_encoding" "$W/run_without.out"; then
        problems="$problems control-failed-for-another-reason"
    fi
    if [ -n "$problems" ]; then fail "install:$problems (see $W)"; else
        pass "install: pixi installs $PKG from a file:// channel with mojo-compiler ==$pin, \`mojo run\` of a program importing it (no -I) prints deadbeef and 3q2+7w==, the env holds $DOC byte-equal to the source README, and the same project without it cannot import it"
    fi
fi

if [ "$fails" = 0 ] && [ -z "${KOMIRA_TEST_KEEP:-}" ]; then rm -rf "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
