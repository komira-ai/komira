#!/usr/bin/env bash
# conda.sh -- tests of the conda packages (tools/build/package/conda.bzl, and
# `komira_pack conda` / `conda-check` behind it), on //packaging/conda:komira_encoding.
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
#              info/paths.json says so; the licence is the repository's;
#              [digest] and [manifest] describe the file's own sha256 and size.
#   pin        the compiler pin in the run requirements is the version of the
#              pinned compiler package in tools/build/toolchains/BUCK.
#   refusals   each named bad package is refused with its reason: a name outside
#              the approved list, a dependency outside it, a name without the
#              prefix, a target not named for the import name, a library with no
#              tests, one that opens a shared library at run time, one linking
#              native code; the two controls build, and one shows a dependency
#              rendered into the run requirements at its own version.
#   lint       //packaging/conda:names_lint is green; a list with every defect,
#              and a BUCK file that declares another package or swaps the list,
#              is red naming each.
#   stamp      the version is <prefix>.N from the configuration: the unstamped
#              build is refused by [release_check]; a stamped one is accepted,
#              carries the stamp in every place, and re-runs no compile (only
#              the packing actions); release_version.sh counts first-parent
#              commits to the last non-documentation commit, in a scratch repo,
#              and refuses a shallow clone.
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

PKG=//packaging/conda:komira_encoding
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

# ---- shape ----------------------------------------------------------------
CONDA=$(out_of "$PKG")
MANIFEST=$(out_of "${PKG}[manifest]")
DIGEST=$(out_of "${PKG}[digest]")
CHECK=$(out_of "${PKG}[check]")
LIBPKG=$(out_of //src/komira_encoding:komira_encoding)
if [ -z "$CONDA" ] || [ -z "$MANIFEST" ] || [ -z "$DIGEST" ] || [ -z "$CHECK" ] || [ -z "$LIBPKG" ]; then
    fail "shape: cannot build $PKG and its sub-targets (see $W/build.log)"
    echo "logs: $W"
    exit 1
fi
problems=""
p() { problems="$problems $1"; }
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
[ "$(cat "$DIGEST")" = "sha256:$file_sha" ] || p digest-differs
jq -e --arg s "$file_sha" --arg p "$want_sha" --argjson z "$(stat -L -c %s "$CONDA")" '.schema == 1 and .artifact_type == "conda"
    and .sha256 == $s and .size == $z and .payload_sha256 == $p and .file_name == "komira_encoding-0.1.0-0.conda"
    and .stamped == false and .name == "komira_encoding" and .subdir == "linux-64" and .version == "0.1.0"
    and .mojo_pin == "1.0.0" and .depends == ["__linux", "mojo-compiler ==1.0.0"]' "$MANIFEST" > /dev/null || p manifest
[ "$(cat "$CHECK")" = ok ] || p check-marker
if [ -n "$problems" ]; then fail "shape:$problems (see $S)"; else
    pass "shape: $PKG is three stored members, two valid zstd streams of owner-0 tars, sorted compact JSON, linux-64, the library's .mojoc byte for byte; digest $file_sha"
fi

# ---- packer ---------------------------------------------------------------
# komira_pack run directly on the client: the same inputs give the same bytes,
# and they are the bytes the rule's action wrote; conda-check refuses what is
# wrong with a package, so a green check is evidence.
PACK=$(out_of //tools/build/package:komira_pack)
SRCS=$(out_of //src/komira_encoding:komira_encoding[src])
NAMES=packaging/conda/names.tsv
pack() { # out-prefix, payload [extra komira_pack args...]
    local o=$1 payload=$2
    shift 2
    "$PACK" conda --name komira_encoding --name-prefix komira_ --names "$NAMES" --version-prefix packaging/conda/VERSION_PREFIX \
        --stamp 0 --timestamp-ms 0 --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary "Base64, base64url, base32 and hex in pure Mojo, with constant-time strict decoding." \
        --home https://github.com/komira-ai/komira --payload "$payload" --sources "$SRCS" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label komira//packaging/conda:komira_encoding \
        --out "$o.conda" --conda-manifest "$o.manifest.json" --digest "$o.digest" "$@"
}
check() { # package manifest payload [extra args...]
    local pkgf=$1 man=$2 payload=$3
    shift 3
    "$PACK" conda-check --package "$pkgf" --conda-manifest "$man" --payload "$payload" --expect-subdir linux-64 \
        --names "$NAMES" --name-prefix komira_ --mojo-pin "$pin" --out "$W/check.marker" "$@"
}
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)
problems=""
pack "$W/pack1" "$LIBPKG" 2> "$W/pack1.err" || problems="$problems pack1-failed"
pack "$W/pack2" "$LIBPKG" 2> "$W/pack2.err" || problems="$problems pack2-failed"
if [ -z "$problems" ]; then
    cmp -s "$W/pack1.conda" "$W/pack2.conda" || problems="$problems two-runs-differ"
    cmp -s "$W/pack1.conda" "$CONDA" || problems="$problems differs-from-the-rule's-package"
    cmp -s "$W/pack1.manifest.json" "$MANIFEST" || problems="$problems manifest-differs"
    check "$W/pack1.conda" "$W/pack1.manifest.json" "$LIBPKG" 2> "$W/check_ok.err" || problems="$problems check-refused-a-good-package"
    # One byte of the payload changed: a different package (only its pkg member and the
    # checksums over it), which the check refuses against the real payload and accepts against its own.
    cp "$LIBPKG" "$W/payload2.mojoc" && chmod u+w "$W/payload2.mojoc" && printf 'X' | dd of="$W/payload2.mojoc" bs=1 seek=100 conv=notrunc 2> /dev/null
    pack "$W/pack3" "$W/payload2.mojoc" 2> "$W/pack3.err" || problems="$problems pack3-failed"
    cmp -s "$W/pack1.conda" "$W/pack3.conda" && problems="$problems a-changed-payload-gave-the-same-package"
    check "$W/pack3.conda" "$W/pack3.manifest.json" "$LIBPKG" 2> "$W/check_payload.err" && problems="$problems check-accepted-a-different-payload"
    grep -q 'the payload differs from the library' "$W/check_payload.err" || problems="$problems check-payload-text"
    check "$W/pack3.conda" "$W/pack3.manifest.json" "$W/payload2.mojoc" 2> /dev/null || problems="$problems check-refused-its-own-payload"
    check "$W/pack1.conda" "$W/pack1.manifest.json" "$LIBPKG" --require-stamped true 2> "$W/check_unstamped.err" && problems="$problems check-accepted-unstamped-as-release"
    printf '# no names\nkomira_other\tx\ty\n' > "$W/other_names.tsv"
    "$PACK" conda-check --package "$W/pack1.conda" --conda-manifest "$W/pack1.manifest.json" --payload "$LIBPKG" --expect-subdir linux-64 \
        --names "$W/other_names.tsv" --name-prefix komira_ --mojo-pin "$pin" --out "$W/check.marker" 2> "$W/check_names.err" && problems="$problems check-accepted-an-unlisted-name"
    grep -q 'is not in the approved list' "$W/check_names.err" || problems="$problems check-names-text"
    "$PACK" conda-check --package "$W/pack1.conda" --conda-manifest "$W/pack1.manifest.json" --payload "$LIBPKG" --expect-subdir osx-arm64 \
        --names "$NAMES" --name-prefix komira_ --mojo-pin "$pin" --out "$W/check.marker" 2> "$W/check_subdir.err" && problems="$problems check-accepted-another-subdir"
    # A package whose zip was edited by one byte is refused (the CRC of a member).
    cp "$W/pack1.conda" "$W/pack4.conda" && printf 'Z' | dd of="$W/pack4.conda" bs=1 seek=200 conv=notrunc 2> /dev/null
    check "$W/pack4.conda" "$W/pack1.manifest.json" "$LIBPKG" 2> "$W/check_zip.err" && problems="$problems check-accepted-a-corrupt-zip"
fi
if [ -n "$problems" ]; then fail "packer:$problems (see $W)"; else
    pass "packer: komira_pack gives byte-identical packages from one payload (and the rule's), changes only the package for a changed payload; conda-check accepts it and refuses a different payload, an unlisted name, another subdir, a corrupt zip and an unstamped release"
fi

# ---- pin --------------------------------------------------------------------
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)
if [ -n "$pin" ] && grep -qF "name = \"mojo_compiler_${pin}_linux-64.conda\"" tools/build/toolchains/BUCK &&
    [ "$(jq -r '.depends[1]' "$S/info/index.json")" = "mojo-compiler ==$pin" ]; then
    pass "pin: the packages require exactly mojo-compiler ==$pin, the version of the pinned compiler package"
else
    fail "pin: MOJO_COMPILER_PIN ('$pin') is not the version of the pinned compiler in tools/build/toolchains/BUCK, or not in the run requirements"
fi

# ---- refusals ---------------------------------------------------------------
N=tests//negative/conda_pkgs
red refuse_unlisted_name "is not in the approved list" $N:komira_neg_unlisted
red refuse_unlisted_dep "dependency \`komira_neg_dep\` of komira_neg_user is not in the approved list" $N:komira_neg_user
red refuse_no_prefix "name \`neg_noprefix\` is not \`komira_\` + lowercase letters" $N:neg_noprefix
red refuse_target_name "the published name is the library's import name \`komira_neg_listed\`" $N:komira_neg_other
red refuse_no_tests "has no tests, so its package would not be gated by any" $N:komira_neg_notests
red refuse_dlopen "opens a shared library at run time (OwnedDLHandle)" $N:komira_neg_dlopen
red refuse_native "links native code" $N:cadd
if "$BUCK2" build $N:komira_neg_listed > "$W/ctl_listed.log" 2>&1 && ou=$(out_of "$N:komira_neg_ok_user[manifest]") &&
    jq -e '.depends == ["__linux", "mojo-compiler ==1.0.0", "komira_neg_listed ==0.1.0"]' "$ou" > /dev/null; then
    pass "controls: the listed fixtures build against their own list, and a dependency is rendered as 'komira_neg_listed ==0.1.0'"
else
    fail "controls: a fixture that must build did not, or its run requirements are wrong (see $W/ctl_listed.log)"
fi

# ---- lint -------------------------------------------------------------------
if "$BUCK2" build //packaging/conda:names_lint > "$W/names_lint.log" 2>&1; then
    pass "lint: //packaging/conda:names_lint is green"
else
    fail "lint: //packaging/conda:names_lint is red (see $W/names_lint.log)"
fi
"$BUCK2" build $N:names_bad > "$W/names_bad.log" 2>&1
problems=""
for text in "is not after" "is not \`komira_\` + lowercase letters, digits and _" "is not //src/komira_wronglabel:komira_wronglabel" \
    "is listed twice" "not three non-empty tab-separated columns" "a conda_package names another approved list" \
    "conda_package targets differ from the rows"; do
    grep -qF -- "$text" "$W/names_bad.log" || problems="$problems [$text]"
done
if [ -n "$problems" ]; then fail "lint: names_bad did not name:$problems (see $W/names_bad.log)"; else pass "lint: a list with every defect, and a BUCK file declaring another package and swapping the list, is red naming each"; fi

# ---- stamp ------------------------------------------------------------------
red release_refuses_unstamped "was never stamped" "${PKG}[release_check]"
# A stamp no earlier run used, so the packing actions execute and the check
# below sees them (a cached run would list nothing, which proves nothing).
N_STAMP=$((100000 + RANDOM))
STAMP="-c komira.package_stamp=$N_STAMP -c komira.package_timestamp_ms=1700000000000"
# shellcheck disable=SC2086 # STAMP is a list of words
if "$BUCK2" build $STAMP "${PKG}[release_check]" > "$W/stamp_check.log" 2>&1; then
    # No compile re-ran for a new stamp: the executed actions are packing, and only that.
    "$BUCK2" log what-ran --skip-cache-hits > "$W/stamp_whatran.txt" 2>&1
    if grep -q 'conda_pack' "$W/stamp_whatran.txt" && ! grep -qE 'mojo_(precompile|build|gated)' "$W/stamp_whatran.txt"; then
        # shellcheck disable=SC2086
        s_manifest=$("$BUCK2" build $STAMP "${PKG}[manifest]" --materializations all --show-full-output 2> "$W/stamp_manifest.log" | sed -n 's/^[^ ]* //p' | tail -n 1)
        if jq -e --arg v "0.1.$N_STAMP" '.version == $v and .stamped == true and .file_name == "komira_encoding-\($v)-0.conda"' "$s_manifest" > /dev/null; then
            pass "stamp: -c komira.package_stamp=$N_STAMP gives 0.1.$N_STAMP (release_check green, manifest, file name) and the new stamp re-ran only the packing actions, no compile"
        else
            fail "stamp: the stamped manifest is not version 0.1.$N_STAMP (see $W/stamp_manifest.log)"
        fi
    else
        fail "stamp: a new stamp re-ran a Mojo action, or no packing action ran (see $W/stamp_whatran.txt)"
    fi
else
    fail "stamp: a stamped build is not accepted by release_check (see $W/stamp_check.log)"
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
g init -q -b main && commit one 1700000100 &&
    echo d > "$R/docs/a.md" && commit docs-only 1700000200 &&
    echo b > "$R/src/x/b.mojo" && commit src 1700000300 &&
    echo r > "$R/src/x/README.md" && mkdir -p "$R/.github" && echo w > "$R/.github/w.yml" && commit md-and-github-only 1700000400
v() { sh "$R/tools/build/package/release_version.sh" "$@" 2>&1; }
problems=""
[ "$(v HEAD~2)" = "$(printf 'version=0.3.1\nbuck_args=-c komira.package_stamp=1 -c komira.package_timestamp_ms=1700000100000')" ] || problems="$problems docs-only-commit:[$(v HEAD~2 | tr '\n' ' ')]"
[ "$(v HEAD~1)" = "$(printf 'version=0.3.3\nbuck_args=-c komira.package_stamp=3 -c komira.package_timestamp_ms=1700000300000')" ] || problems="$problems source-commit:[$(v HEAD~1 | tr '\n' ' ')]"
[ "$(v HEAD)" = "$(v HEAD~1)" ] || problems="$problems documentation-commit-changed-the-version"
git clone -q --depth 1 "file://$R" "$W/shallow" 2> /dev/null && cp -r "$R/tools" "$W/shallow/" &&
    sh "$W/shallow/tools/build/package/release_version.sh" > "$W/shallow.out" 2>&1 && problems="$problems shallow-clone-accepted"
grep -q 'shallow clone' "$W/shallow.out" || problems="$problems shallow-refusal-text"
[ -z "$problems" ] && pass "stamp: release_version.sh gives 0.3.<count to the last non-documentation commit> and its timestamp, ignores docs/, *.md and .github/, refuses a shallow clone" ||
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
            cp -L "$f" "$W/uncached_$n.conda"
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
if [ "$install" = 1 ] && command -v pixi > /dev/null && curl -fsS -o /dev/null -I https://repo.prefix.dev/max-nightly/linux-64/repodata.json 2> /dev/null; then
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
            printf '[workspace]\nname = "komira-conda-test"\nchannels = ["file://%s", "https://repo.prefix.dev/max-nightly", "conda-forge"]\nplatforms = ["linux-64"]\n\n[dependencies]\n' "$C"
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
    echo "SKIP  conda install ($([ "$install" = 1 ] || echo '--no-install'; command -v pixi > /dev/null || echo 'no pixi'; [ "$install" = 0 ] || curl -fsS -o /dev/null -I https://repo.prefix.dev/max-nightly/linux-64/repodata.json 2> /dev/null || echo 'no network'))"
fi

if [ "$fails" = 0 ] && [ -z "${KOMIRA_TEST_KEEP:-}" ]; then rm -rf "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
