#!/usr/bin/env bash
# conda.sh -- tests of the conda packages (tools/build/package/conda.bzl, and
# `komira_pack conda` / `conda-check` behind it), on //src/komira_encoding:komira_encoding_conda
# and the fixture libraries of tests//negative/conda.
#
# usage: tools/build/tests/functional/conda.sh [--no-uncached] [--no-install]   (from anywhere; BUCK2 overrides;
#        KOMIRA_TEST_KEEP=1 keeps the scratch directory, with every log, after a pass)
#
#   shape      the .conda is read with tools that are not the writer's: unzip
#              (three stored members, in order), zstd (both streams valid), tar
#              (regular files, owner 0/0, no mtime), jq (sorted compact JSON); the
#              info/ files a consumer reads are all there; index.json has exactly
#              the expected keys (no `noarch`), linux-64, build 0, the run
#              requirements in order (guard, exact mojo-compiler pin); the one
#              payload file is the library's .mojoc, byte for byte, and
#              info/paths.json says so; the licence is the repository's. The
#              package is a directory: the .conda, `manifest.json` and
#              `metadata.json`. manifest.json is EXACTLY the artifact manifest
#              contract of kci (seven string keys in a fixed order, compact,
#              one trailing newline, `file` the channel's file name, `sha256` the
#              file's, `metadata` the bare name `metadata.json`); every other
#              fact is in metadata.json.
#   pin        the compiler pin in the run requirements is the version of the
#              pinned compiler package in tools/build/toolchains/BUCK.
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
#              list, a corrupt zip, an unstamped release, a manifest that is not
#              the contract (an extra key, no `metadata` or another one, another
#              key order, no newline, a wrong sha256), a metadata file that
#              disagrees, and a stray file in the directory.
#   stamp      the version is <prefix>.N from the configuration: the unstamped
#              build is refused by [release_check] and has no [release]; a
#              stamp without its source commit is refused; a stamped one is
#              accepted, carries the stamp and commit in every place, and
#              re-runs no compile (only the packing actions); [release]
#              exists only then. Via komira_pack directly: a commit time that
#              is not positive is refused by the release check, a short commit
#              by the packer.
#              release_version.sh counts first-parent commits to the last
#              non-documentation commit, in a scratch repo, prints that commit,
#              and refuses a shallow clone.
#   copies     the built directory is copied before anything else is built, and
#              every later step reads the copy: under local execution a second
#              build of the same target with another configuration overwrites the
#              buck-out path.
#   uncached   two builds in two fresh daemons with --no-remote-cache, one isolation
#              directory, give the same sha256 (skipped with --no-uncached).
#   install    a pixi project whose channel is the built file served from a
#              file:// directory (its repodata.json is written here) installs it
#              with the pinned compiler, and `mojo run` of a program importing
#              the library, with no -I, prints the right bytes; the same project
#              without the package cannot import it. Needs pixi, jq and network
#              (the compiler comes from the channel it is pinned to); otherwise SKIP.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 2
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
uncached=1
install=1
for a in "$@"; do
    case "$a" in
        --no-uncached) uncached=0 ;;
        --no-install) install=0 ;;
        *) echo "conda.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_conda.XXXXXX")
fails=0
pass() { echo "PASS  conda $1"; }
fail() { echo "FAIL  conda $1"; fails=$((fails + 1)); }

for tool in unzip zstd tar jq sha256sum cmp git; do
    command -v "$tool" > /dev/null || { echo "FAIL  conda needs $tool on PATH"; exit 1; }
done

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
CONDA=$K/pkg/komira_encoding-0.1.0-0.conda MANIFEST=$K/pkg/manifest.json METADATA=$K/pkg/metadata.json CHECK=$K/package.check LIBPKG=$K/library.mojoc
problems=""
p() { problems="$problems $1"; }
[ "$(ls "$K/pkg" | tr '\n' ' ')" = "komira_encoding-0.1.0-0.conda manifest.json metadata.json " ] || p "directory:[$(ls "$K/pkg" | tr '\n' ' ')]"
S="$W/shape"
mkdir -p "$S"
unzip -q -o "$CONDA" -d "$S" || p unzip
names=$(unzip -Z1 "$CONDA" | tr '\n' ' ')
[ "$names" = "metadata.json pkg-komira_encoding-0.1.0-0.tar.zst info-komira_encoding-0.1.0-0.tar.zst " ] || p "members:[$names]"
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
[ "$(tar -tf "$S/pkg.tar")" = "lib/mojo/komira_encoding.mojoc" ] || p "pkg-files"
cmp -s "$S/lib/mojo/komira_encoding.mojoc" "$LIBPKG" || p payload-differs-from-library
cmp -s "$S/info/licenses/LICENSE" "$ROOT/LICENSE" || p licence
for f in info/index.json info/paths.json info/about.json; do
    [ "$(jq -S -c . "$S/$f")" = "$(cat "$S/$f")" ] || p "$f-not-sorted-compact"
done
jq -e '(keys == ["arch","build","build_number","depends","license","name","platform","subdir","timestamp","version"])
    and .name == "komira_encoding" and .subdir == "linux-64" and .platform == "linux" and .arch == "x86_64"
    and .build == "0" and .build_number == 0 and .version == "0.1.0" and .license == "Apache-2.0"
    and (has("noarch") | not)
    and .depends == ["__linux", "mojo-compiler ==1.0.0"]' "$S/info/index.json" > /dev/null || p index.json
want_sha=$(sha256sum "$S/lib/mojo/komira_encoding.mojoc" | cut -c1-64)
jq -e --arg s "$want_sha" '.paths_version == 1 and (.paths | length) == 1 and .paths[0]._path == "lib/mojo/komira_encoding.mojoc"
    and .paths[0].path_type == "hardlink" and .paths[0].sha256 == $s' "$S/info/paths.json" > /dev/null || p paths.json
[ "$(jq .paths[0].size_in_bytes "$S/info/paths.json")" = "$(stat -L -c %s "$LIBPKG")" ] || p paths-size
file_sha=$(sha256sum "$CONDA" | cut -c1-64)
# manifest.json: exactly kci's artifact manifest contract.
jq -e --arg s "$file_sha" '(keys_unsorted == ["artifact_type","name","version","subdir","file","sha256","metadata"])
    and .artifact_type == "CONDA" and .name == "komira_encoding" and .version == "0.1.0" and .subdir == "linux-64"
    and .file == "komira_encoding-0.1.0-0.conda" and .sha256 == $s and .metadata == "metadata.json"' "$MANIFEST" > /dev/null || p manifest-contract
[ "$(jq -c . "$MANIFEST")" = "$(head -c -1 "$MANIFEST")" ] && [ "$(tail -c 1 "$MANIFEST" | od -An -c | tr -d ' ')" = '\n' ] || p manifest-not-compact-with-newline
# metadata.json: everything else.
jq -e --arg s "$file_sha" --arg p "$want_sha" --argjson z "$(stat -L -c %s "$CONDA")" '.schema == 1 and .kind == "library"
    and .size == $z and .payload_sha256 == $p and .file_name == "komira_encoding-0.1.0-0.conda" and .payload_path == "lib/mojo/komira_encoding.mojoc"
    and .stamped == false and .source_commit == "" and .name == "komira_encoding" and .import_name == "komira_encoding"
    and .subdir == "linux-64" and .version == "0.1.0" and .timestamp_ms == 0 and .build == "0" and .build_number == 0
    and .mojo_pin == "1.0.0" and .depends == ["__linux", "mojo-compiler ==1.0.0"]
    and .label == "komira//src/komira_encoding:komira_encoding_conda"' "$METADATA" > /dev/null || p metadata
[ "$(jq -S -c . "$METADATA")" = "$(cat "$METADATA")" ] || p metadata-not-sorted-compact
[ "$(cat "$CHECK")" = ok ] || p check-marker
if [ -n "$problems" ]; then fail "shape:$problems (see $S)"; else
    pass "shape: $PKG is a directory of the .conda (three stored members, two valid zstd streams of owner-0 tars, linux-64, the library's .mojoc byte for byte), the artifact manifest (exactly the seven contract keys, \`metadata\` naming metadata.json) and the metadata; sha256 $file_sha"
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
    "$PACK" conda --name komira_encoding --import-name komira_encoding --version-prefix packaging/conda/VERSION_PREFIX \
        --stamp 0 --timestamp-ms 0 --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary "$SUMMARY" --home https://github.com/komira-ai/komira --payload "$payload" --sources "$SRCS" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "$LABEL" --out-dir "$o" "$@"
}
packs() { # out-dir, stamp, timestamp-ms [extra komira_pack args...]: a stamped package
    local o=$1 st=$2 ts=$3
    shift 3
    "$PACK" conda --name komira_encoding --import-name komira_encoding --version-prefix packaging/conda/VERSION_PREFIX \
        --stamp "$st" --timestamp-ms "$ts" --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary "s" --home https://github.com/komira-ai/komira --payload "$LIBPKG" --sources "$SRCS" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "$LABEL" --out-dir "$o" "$@"
}
check() { # dir payload [extra args...]
    local d=$1 payload=$2
    shift 2
    "$PACK" conda-check --dir "$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$payload" --out "$W/check.marker" "$@"
}
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)
problems=""
pack "$W/pack1" "$LIBPKG" 2> "$W/pack1.err" || problems="$problems pack1-failed"
pack "$W/pack2" "$LIBPKG" 2> "$W/pack2.err" || problems="$problems pack2-failed"
if [ -z "$problems" ]; then
    cmp -s "$W/pack1/komira_encoding-0.1.0-0.conda" "$W/pack2/komira_encoding-0.1.0-0.conda" || problems="$problems two-runs-differ"
    cmp -s "$W/pack1/komira_encoding-0.1.0-0.conda" "$CONDA" || problems="$problems differs-from-the-rule's-package"
    cmp -s "$W/pack1/manifest.json" "$MANIFEST" || problems="$problems manifest-differs"
    cmp -s "$W/pack1/metadata.json" "$METADATA" || problems="$problems metadata-differs"
    check "$W/pack1" "$LIBPKG" 2> "$W/check_ok.err" || problems="$problems check-refused-a-good-package"
    # One byte of the payload changed: a different package (only its pkg member and the
    # checksums over it), which the check refuses against the real payload and accepts against its own.
    cp "$LIBPKG" "$W/payload2.mojoc" && chmod u+w "$W/payload2.mojoc" && printf 'X' | dd of="$W/payload2.mojoc" bs=1 seek=100 conv=notrunc 2> /dev/null
    pack "$W/pack3" "$W/payload2.mojoc" 2> "$W/pack3.err" || problems="$problems pack3-failed"
    cmp -s "$W/pack1/komira_encoding-0.1.0-0.conda" "$W/pack3/komira_encoding-0.1.0-0.conda" && problems="$problems a-changed-payload-gave-the-same-package"
    check "$W/pack3" "$LIBPKG" 2> "$W/check_payload.err" && problems="$problems check-accepted-a-different-payload"
    grep -q 'the payload differs from the library' "$W/check_payload.err" || problems="$problems check-payload-text"
    check "$W/pack3" "$W/payload2.mojoc" 2> /dev/null || problems="$problems check-refused-its-own-payload"
    check "$W/pack1" "$LIBPKG" --require-stamped true 2> "$W/check_unstamped.err" && problems="$problems check-accepted-unstamped-as-release"
    grep -q 'never stamped' "$W/check_unstamped.err" || problems="$problems unstamped-text"
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_other --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --out "$W/check.marker" 2> "$W/check_name.err" && problems="$problems check-accepted-another-name"
    "$PACK" conda-check --dir "$W/pack1" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir osx-arm64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --out "$W/check.marker" 2> "$W/check_subdir.err" && problems="$problems check-accepted-another-subdir"
    # The caller states the dependencies; a package that requires others, or fewer, is refused.
    check "$W/pack1" "$LIBPKG" --dep komira_json 2> "$W/check_dep.err" && problems="$problems check-accepted-a-missing-dependency"
    grep -q 'index depends has' "$W/check_dep.err" || problems="$problems check-dep-text"
    # A package whose zip was edited by one byte is refused.
    cp -r "$W/pack1" "$W/pack4" && chmod -R u+w "$W/pack4" && printf 'Z' | dd of="$W/pack4/komira_encoding-0.1.0-0.conda" bs=1 seek=200 conv=notrunc 2> /dev/null
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
    mutate manifest-other-order '{name, artifact_type, version, subdir, file, sha256, metadata}'
    mutate manifest-wrong-sha '.sha256 = ("0" * 64)'
    mutate manifest-wrong-type '.artifact_type = "conda"'
    mutate manifest-wrong-file '.file = "x.conda"'
    mutate manifest-no-newline "raw:$(jq -c . "$W/pack1/manifest.json")"
    mutate metadata-wrong-size 'meta:.size += 1'
    mutate metadata-wrong-kind 'meta:.kind = "metapackage"'
    mutate metadata-wrong-payload 'meta:.payload_sha256 = ("1" * 64)'
    grep -q 'exactly the seven keys' "$W/mut_manifest-extra-key.err" || problems="$problems extra-key-text"
    grep -q 'exactly the seven keys' "$W/mut_manifest-no-metadata.err" || problems="$problems no-metadata-text"
    grep -q 'is `meta.json`, must be `metadata.json`' "$W/mut_manifest-other-metadata.err" || problems="$problems other-metadata-text"
    cp -r "$W/pack1" "$W/pack5" && chmod -R u+w "$W/pack5" && echo stray > "$W/pack5/stray.txt"
    check "$W/pack5" "$LIBPKG" 2> "$W/check_stray.err" && problems="$problems check-accepted-a-stray-file"
fi
# The release gate: what makes a package one an uploader may read.
if [ -z "$problems" ]; then
    C40=0123456789abcdef0123456789abcdef01234567
    packs "$W/rel_ok" 7 86400000 --commit "$C40" 2> "$W/rel_ok.err" || problems="$problems stamped-pack-failed"
    "$PACK" conda-check --dir "$W/rel_ok" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
        --mojo-pin "$pin" --payload "$LIBPKG" --require-stamped true --out "$W/check.marker" 2> "$W/rel_ok_check.err" || problems="$problems release-check-refused-a-good-release"
    jq -e --arg c "$C40" '.stamped == true and .version == "0.1.7" and .source_commit == $c and .timestamp_ms == 86400000' "$W/rel_ok/metadata.json" > /dev/null || problems="$problems metadata-lacks-source-commit"
    jq -e '.version == "0.1.7" and .file == "komira_encoding-0.1.7-0.conda"' "$W/rel_ok/manifest.json" > /dev/null || problems="$problems manifest-version"
    for case_ in "rel_ts0:0:timestamp is not positive" "rel_tsneg:-5:timestamp is not positive"; do
        d=${case_%%:*} rest=${case_#*:} ts=${rest%%:*} text=${rest#*:}
        packs "$W/$d" 7 "$ts" --commit "$C40" 2> /dev/null || problems="$problems $d-pack-failed"
        "$PACK" conda-check --dir "$W/$d" --kind library --name komira_encoding --import-name komira_encoding --expect-subdir linux-64 \
            --mojo-pin "$pin" --payload "$LIBPKG" --require-stamped true --out "$W/check.marker" 2> "$W/$d.err" && problems="$problems release-check-accepted-$d"
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

# ---- pin --------------------------------------------------------------------
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)
if [ -n "$pin" ] && grep -qF "package = \":mojo_compiler_${pin}_linux-64.conda\"" tools/build/toolchains/BUCK &&
    [ "$(jq -r '.depends[1]' "$S/info/index.json")" = "mojo-compiler ==$pin" ]; then
    pass "pin: the packages require exactly mojo-compiler ==$pin, the version of the pinned compiler package"
else
    fail "pin: MOJO_COMPILER_PIN ('$pin') is not the version of the pinned compiler in tools/build/toolchains/BUCK, or not in the run requirements"
fi

# ---- generated: no declaration anywhere -------------------------------------
# A library gets its package from the mojo_library macro. No BUCK file of this
# repository declares one by hand, and a new fixture library needs nothing.
problems=""
hand=$(git grep -lE '^[[:space:]]*conda_package\(' -- '*BUCK' || true)
[ -z "$hand" ] || problems="$problems a-BUCK-file-declares-a-package-by-hand:[$hand]"
d=$(out_of "$FX:fx_plain_conda") || problems="$problems fx_plain_conda-does-not-build"
if [ -n "$d" ] && [ -f "$d/manifest.json" ]; then
    jq -e '.name == "fx_plain" and .version == "0.1.0" and .file == "fx_plain-0.1.0-0.conda"' "$d/manifest.json" > /dev/null || problems="$problems fx_plain-manifest"
    jq -e '.depends == ["__linux", "mojo-compiler ==1.0.0"] and .import_name == "fx_plain" and .payload_path == "lib/mojo/fx_plain.mojoc"' "$d/metadata.json" > /dev/null || problems="$problems fx_plain-metadata"
    "$BUCK2" build "$FX:fx_plain_conda[check]" > "$W/fx_plain_check.log" 2>&1 || problems="$problems fx_plain-check-red"
fi
# a dependency is rendered at its own version, by its published name
d=$(out_of "$FX:fx_user_conda")
jq -e '.depends == ["__linux", "mojo-compiler ==1.0.0", "fx_plain ==0.1.0"]' "$d/metadata.json" > /dev/null 2>&1 || problems="$problems fx_user-requirement"
# conda_name: published under another name; the import name is unchanged; a dependent requires the published name
d=$(out_of "$FX:fx_renamed_conda")
if [ -f "$d/fx_published-0.1.0-0.conda" ]; then
    jq -e '.name == "fx_published" and .file == "fx_published-0.1.0-0.conda"' "$d/manifest.json" > /dev/null || problems="$problems fx_renamed-manifest"
    jq -e '.import_name == "fx_renamed" and .payload_path == "lib/mojo/fx_renamed.mojoc"' "$d/metadata.json" > /dev/null || problems="$problems fx_renamed-payload-path"
else
    problems="$problems fx_renamed-file:[$(ls "$d" | tr '\n' ' ')]"
fi
d=$(out_of "$FX:fx_renamed_user_conda")
jq -e '.depends == ["__linux", "mojo-compiler ==1.0.0", "fx_published ==0.1.0"]' "$d/metadata.json" > /dev/null 2>&1 || problems="$problems fx_renamed_user-requirement"
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
        if jq -e --arg v "0.1.$N_STAMP" '.version == $v and .file == "komira_encoding-\($v)-0.conda"' "$s_manifest" > /dev/null &&
            jq -e --arg v "0.1.$N_STAMP" --arg c "$C_STAMP" '.version == $v and .stamped == true and .source_commit == $c and .timestamp_ms == 86400000' "$s_meta" > /dev/null &&
            [ "$(jq -r .sha256 "$s_manifest")" = "$(sha256sum < "$s_dir/$(jq -r .file "$s_manifest")" | cut -c1-64)" ]; then
            pass "stamp: -c komira.package_stamp=$N_STAMP gives 0.1.$N_STAMP ([release] green: manifest with the file name and sha256 of the file, metadata with the stamp and source commit) and the new stamp re-ran only the packing actions, no compile"
        else
            fail "stamp: the stamped package is not version 0.1.$N_STAMP (see $W/stamp_manifest.log)"
        fi
    else
        fail "stamp: a new stamp re-ran a Mojo action, or no packing action ran (see $W/stamp_whatran.txt)"
    fi
else
    fail "stamp: a stamped build is not accepted by [release] (see $W/stamp_check.log)"
fi

R="$W/repo"
mkdir -p "$R/packaging/conda" "$R/src/x" "$R/docs" "$R/tools/build/package"
cp tools/build/package/release_version.sh "$R/tools/build/package/"
printf '0.3\n' > "$R/packaging/conda/VERSION_PREFIX"
echo a > "$R/src/x/a.mojo"
g() { GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    git -C "$R" "$@"; }
commit() { # message, epoch
    g add -A && GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" g commit -q -m "$1"
}
g init -q -b main && commit one 100000100 &&
    echo d > "$R/docs/a.md" && commit docs-only 100000200 &&
    echo b > "$R/src/x/b.mojo" && commit src 100000300 &&
    echo r > "$R/src/x/README.md" && mkdir -p "$R/.github" && echo w > "$R/.github/w.yml" && commit md-and-github-only 100000400
v() { sh "$R/tools/build/package/release_version.sh" "$@" 2>&1; }
problems=""
c1=$(g rev-parse HEAD~3) c3=$(g rev-parse HEAD~1)
[ "$(v HEAD~2)" = "$(printf 'version=0.3.1\ncommit=%s\nbuck_args=-c komira.package_stamp=1 -c komira.package_commit=%s -c komira.package_timestamp_ms=100000100000' "$c1" "$c1")" ] || problems="$problems docs-only-commit:[$(v HEAD~2 | tr '\n' ' ')]"
[ "$(v HEAD~1)" = "$(printf 'version=0.3.3\ncommit=%s\nbuck_args=-c komira.package_stamp=3 -c komira.package_commit=%s -c komira.package_timestamp_ms=100000300000' "$c3" "$c3")" ] || problems="$problems source-commit:[$(v HEAD~1 | tr '\n' ' ')]"
[ "$(v HEAD)" = "$(v HEAD~1)" ] || problems="$problems documentation-commit-changed-the-version"
git clone -q --depth 1 "file://$R" "$W/shallow" 2> /dev/null && cp -r "$R/tools" "$W/shallow/" &&
    sh "$W/shallow/tools/build/package/release_version.sh" > "$W/shallow.out" 2>&1 && problems="$problems shallow-clone-accepted"
grep -q 'shallow clone' "$W/shallow.out" || problems="$problems shallow-refusal-text"
[ -z "$problems" ] && pass "stamp: release_version.sh gives 0.3.<count to the last non-documentation commit>, that commit and its timestamp, ignores docs/, *.md and .github/, refuses a shallow clone" ||
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

# ---- install ----------------------------------------------------------------
if [ "$install" = 1 ] && command -v pixi > /dev/null && curl -fsSL -o /dev/null -I https://conda.modular.com/max/linux-64/repodata.json 2> /dev/null; then
    C="$W/channel"
    mkdir -p "$C/linux-64" "$C/noarch" "$W/with" "$W/without"
    cp "$CONDA" "$C/linux-64/komira_encoding-0.1.0-0.conda"
    # The index: each package's info/index.json, plus the file's sha256 and size.
    unzip -p "$CONDA" 'info-*' | zstd -dc | tar -xO -f - info/index.json > "$W/index.json"
    jq -n --slurpfile i "$W/index.json" --arg s "$file_sha" --argjson z "$(stat -L -c %s "$CONDA")" \
        '{info: {subdir: "linux-64"}, packages: {}, "packages.conda": {"komira_encoding-0.1.0-0.conda": ($i[0] + {sha256: $s, size: $z})}, removed: [], repodata_version: 1}' > "$C/linux-64/repodata.json"
    jq -n '{info: {subdir: "noarch"}, packages: {}, "packages.conda": {}, removed: [], repodata_version: 1}' > "$C/noarch/repodata.json"
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
            if [ "$variant" = with ]; then printf 'komira_encoding = "==0.1.0"\n'; else printf 'mojo-compiler = "==%s"\n' "$pin"; fi
        } > "$W/$variant/pixi.toml"
        cp "$W/hello.mojo" "$W/$variant/hello.mojo"
    done
    export PIXI_CACHE_DIR="$W/pixi_cache" PIXI_HOME="$W/pixi_home"
    problems=""
    pixi install --manifest-path "$W/with/pixi.toml" > "$W/install_with.log" 2>&1 || problems="$problems install-failed"
    if [ -z "$problems" ]; then
        [ -f "$W/with/.pixi/envs/default/lib/mojo/komira_encoding.mojoc" ] || problems="$problems payload-not-installed-at-lib/mojo"
        cmp -s "$W/with/.pixi/envs/default/lib/mojo/komira_encoding.mojoc" "$LIBPKG" || problems="$problems installed-payload-differs"
        grep -qF "mojo-compiler" "$W/with/pixi.lock" && grep -q "komira_encoding-0.1.0-0.conda" "$W/with/pixi.lock" || problems="$problems lock-lacks-the-packages"
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
        pass "install: pixi installs $PKG from a file:// channel with mojo-compiler ==$pin, \`mojo run\` of a program importing it (no -I) prints deadbeef and 3q2+7w==, and the same project without it cannot import it"
    fi
else
    echo "SKIP  conda install ($([ "$install" = 1 ] || echo '--no-install'; command -v pixi > /dev/null || echo 'no pixi'; [ "$install" = 0 ] || curl -fsSL -o /dev/null -I https://conda.modular.com/max/linux-64/repodata.json 2> /dev/null || echo 'no network'))"
fi

if [ "$fails" = 0 ] && [ -z "${KOMIRA_TEST_KEEP:-}" ]; then rm -rf "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
