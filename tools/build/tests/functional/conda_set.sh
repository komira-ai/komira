#!/usr/bin/env bash
# conda_set.sh -- tests of the release SET of conda packages (tools/build/package/conda_set.bzl,
# `komira_pack conda-meta`, `conda-meta-check` and `conda-set` behind it), on the TEST list in
# tests//conda_set (the libraries that have tests, no native code and no run-time shared library;
# tools/build/tests/conda_set/names.tsv says it is not an approval).
#
# usage: tools/build/tests/functional/conda_set.sh [--no-uncached] [--no-install]   (from anywhere; BUCK2 overrides;
#        KOMIRA_TEST_KEEP=1 keeps the scratch directory, with every log, after a pass)
#
#   generated  one conda_package target per row of the list, plus `metapackage` and
#              `release_set`, and nothing else: no package is stated by hand, so a row added to a
#              list adds a package (shown on a scratch list of two rows).
#   release    the release set directory holds every package as <name>.conda and release_set.json;
#              the manifest lists every artifact with its channel file name, sha256 (which is the
#              file's), size, depends, version and source commit, one version and one commit across
#              the set, the metapackage LAST in upload_order; every requirement is inside the set
#              or the guard and the compiler pin; the metapackage holds no file and pins every
#              library exactly.
#   unstamped  an unstamped build has no release set (the members have no [release]).
#   refusals   `komira_pack conda-set` refuses, naming it: a missing member, version skew, a
#              dependency outside the set, a manifest that disagrees with the file, a changed file,
#              a member not on the list, a metapackage that pins fewer libraries, a metapackage
#              named like a library; `conda-meta-check` refuses a metapackage of another list.
#              The good set passes the same invocation (the controls).
#   uncached   two builds in two fresh daemons with --no-remote-cache, one isolation directory, give
#              the same sha256 for every file of the set (skipped with --no-uncached).
#   install    pixi installs ONLY the metapackage from a file:// channel of the set, the solver
#              brings every library and the compiler, and `mojo run` of a program importing two
#              libraries prints the right bytes; without the metapackage the import fails.
#              Needs pixi, jq and network; otherwise SKIP.
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
        *) echo "conda_set.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_conda_set.XXXXXX")
fails=0
pass() { echo "PASS  conda_set $1"; }
fail() { echo "FAIL  conda_set $1"; fails=$((fails + 1)); }

for tool in unzip zstd tar jq sha256sum cmp; do
    command -v "$tool" > /dev/null || { echo "FAIL  conda_set needs $tool on PATH"; exit 1; }
done

T=tests//conda_set
TN=tools/build/tests/conda_set/names.tsv
META_NAME_FILE=packaging/conda/METAPACKAGE
C40=0123456789abcdef0123456789abcdef01234567
STAMP="-c komira.package_stamp=7 -c komira.package_commit=$C40 -c komira.package_timestamp_ms=86400000"
VERSION=$(tr -d ' \t\r\n' < packaging/conda/VERSION_PREFIX).7
NAMES=$(grep -vE '^(#|$)' "$TN" | cut -f1)
COUNT=$(echo "$NAMES" | wc -l | tr -d ' ')
META=$(tr -d ' \t\r\n' < "$META_NAME_FILE")
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)

out_of() { # target [buck2 args...] -> its full output path
    local t=$1
    shift
    "$BUCK2" build "$t" "$@" --materializations all --show-full-output 2>> "$W/build.log" | sed -n 's/^[^ ]* //p' | tail -n 1
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

# ---- generated -------------------------------------------------------------
targets=$("$BUCK2" targets "$T:" 2> "$W/targets.err" | sed 's/^[^:]*://' | grep -v '^doc_tree$' | sort | tr '\n' ' ')
want=$( { echo "$NAMES"; printf 'metapackage\nnames.tsv\nrelease_set\n'; } | sort | tr '\n' ' ')
if [ "$targets" = "$want" ]; then
    pass "generated: $T holds a package per row of its list ($COUNT), the metapackage and the release set, and nothing else"
else
    fail "generated: the targets of $T are not one per row plus metapackage and release_set (got: $targets; want: $want)"
fi
if grep -qE '^conda_package\(' packaging/conda/BUCK tools/build/tests/conda_set/BUCK; then
    fail "generated: a BUCK file states a conda_package by hand"
else
    pass "generated: neither //packaging/conda nor $T states a conda_package by hand"
fi
# A row added to a list adds a package, and nothing else is written.
AD=tools/build/tests/zz_conda_set_add_test
trap 'rm -r -f "${ROOT:?}/${AD:?}"' EXIT
mkdir -p "$ROOT/$AD" && {
    printf 'komira_aa\t//src/komira_aa:komira_aa\tx\nkomira_bb\t//src/komira_bb:komira_bb\tx\n' > "$ROOT/$AD/names.tsv"
    sh tools/build/package/gen_conda_names.sh "$ROOT/$AD/names.tsv" > "$ROOT/$AD/names.bzl"
    printf 'load("@komira//tools/build/package:conda_set.bzl", "conda_release")\nload(":names.bzl", "APPROVED")\n\nexport_file(name = "names.tsv")\n\nconda_release(entries = APPROVED, names = "names.tsv")\n' > "$ROOT/$AD/BUCK"
}
added=$("$BUCK2" targets "tests//zz_conda_set_add_test:" 2> "$W/add.err" | sed 's/^[^:]*://' | grep -v '^doc_tree$' | sort | tr '\n' ' ')
if [ "$added" = "komira_aa komira_bb metapackage names.tsv release_set " ]; then
    pass "generated: a list of two rows gives exactly two packages (komira_aa, komira_bb), the metapackage and the release set"
else
    fail "generated: a scratch list of two rows gave: $added (see $W/add.err)"
fi
rm -r -f "${ROOT:?}/${AD:?}"

# ---- the release set --------------------------------------------------------
# shellcheck disable=SC2086 # STAMP is a list of words
SETDIR=$(out_of "$T:release_set" $STAMP)
if [ -z "$SETDIR" ] || [ ! -f "$SETDIR/release_set.json" ]; then
    fail "release: cannot build $T:release_set (see $W/build.log)"
    echo "logs: $W"
    exit 1
fi
# Copies, used for the rest of the script (a build with another configuration reuses the buck-out path).
K="$W/keep"
mkdir -p "$K/m"
cp -rL "$SETDIR" "$K/set" && chmod -R u+w "$K/set"
for n in $NAMES; do
    # shellcheck disable=SC2086
    m=$(out_of "$T:${n}[release][manifest]" $STAMP) && cp -L "$m" "$K/m/$n.manifest.json"
done
# shellcheck disable=SC2086
m=$(out_of "$T:metapackage[release][manifest]" $STAMP) && cp -L "$m" "$K/m/$META.manifest.json"
SET=$K/set/release_set.json
problems=""
p() { problems="$problems $1"; }
[ "$(find "$K/set" -type f | wc -l | tr -d ' ')" = "$((COUNT + 2))" ] || p "files-in-the-set-directory:$(find "$K/set" -type f | wc -l)"
jq -e --arg v "$VERSION" --arg c "$C40" --arg m "$META" --argjson n "$COUNT" --arg h "$(echo "$NAMES" | LC_ALL=C sort | sha256sum | cut -c1-64)" \
    '.schema == 1 and .artifact_type == "conda-release-set" and .version == $v and .source_commit == $c and .subdir == "linux-64"
     and .metapackage == $m and .member_count == $n and .mojo_pin == "1.0.0" and .approved_names_sha256 == $h
     and (.artifacts | length) == $n + 1 and (.upload_order | length) == $n + 1
     and .artifacts[-1].role == "metapackage" and .artifacts[-1].name == $m and ([.artifacts[:-1][] | .role] | unique) == ["member"]
     and .upload_order == [.artifacts[].file_name] and (.upload_order[-1] == "\($m)-\($v)-0.conda")
     and ([.artifacts[:-1][].name] == ([.artifacts[:-1][].name] | sort))
     and ([.artifacts[] | .version] | unique) == [$v] and ([.artifacts[] | .source_commit] | unique) == [$c]' "$SET" > /dev/null || p release_set.json
for n in $NAMES $META; do
    f="$K/set/$n.conda"
    [ -f "$f" ] || { p "missing-$n"; continue; }
    jq -e --arg n "$n" --arg s "$(sha256sum < "$f" | cut -c1-64)" --argjson z "$(stat -L -c %s "$f")" --arg v "$VERSION" \
        '.artifacts[] | select(.name == $n) | .sha256 == $s and .size == $z and .path == "\($n).conda" and .file_name == "\($n)-\($v)-0.conda"' "$SET" > /dev/null || p "artifact-$n"
done
# every requirement of a library: the guard, the compiler pin, or a library of the set at this version
set_names=$(jq -r '.artifacts[] | .name' "$SET" | sort | tr '\n' ' ')
for n in $NAMES; do
    while read -r d; do
        case "$d" in
            "__linux" | "mojo-compiler ==$pin") ;;
            *" ==$VERSION") echo "$set_names" | grep -qw "${d% ==*}" || p "$n-requires-outside-the-set:$d" ;;
            *) p "$n-requires:$d" ;;
        esac
    done < <(jq -r --arg n "$n" '.artifacts[] | select(.name == $n) | .depends[]' "$SET")
done
# the metapackage: no file, the guard and every library pinned exactly
M="$W/meta"
mkdir -p "$M"
unzip -q -o "$K/set/$META.conda" -d "$M" || p meta-unzip
zstd -dc "$M"/pkg-*.tar.zst | tar -tf - 2> /dev/null | grep -q . && p meta-has-files
zstd -dc "$M"/info-*.tar.zst | tar -xf - -C "$M" || p meta-info
[ "$(jq -c . "$M/info/paths.json")" = '{"paths":[],"paths_version":1}' ] || p meta-paths
want_meta=$( { echo '"__linux"'; for n in $(echo "$NAMES" | LC_ALL=C sort); do echo "\"$n ==$VERSION\""; done; } | jq -sc .)
[ "$(jq -c .depends "$M/info/index.json")" = "$want_meta" ] || p "meta-requirements:$(jq -c .depends "$M/info/index.json" | cut -c1-120)"
jq -e --arg m "$META" --arg v "$VERSION" '.name == $m and .version == $v and .subdir == "linux-64" and (keys | length) == 10 and (has("noarch") | not)' "$M/info/index.json" > /dev/null || p meta-index
if [ -n "$problems" ]; then fail "release:$problems (see $W)"; else
    pass "release: a directory of $((COUNT + 1)) packages and release_set.json: version $VERSION and one source commit across the set, every sha256 the file's, every requirement inside the set or the guard and compiler pin, '$META' last in upload_order, pinning exactly the $COUNT libraries and holding no file"
fi

# ---- unstamped ----------------------------------------------------------------
red release_set_refuses_unstamped "was never stamped" "$T:release_set"
red metapackage_refuses_unstamped "was never stamped" "$T:metapackage[release]"

# ---- refusals, by komira_pack directly ------------------------------------------
PACK=$(out_of //tools/build/package:komira_pack)
setrun() { # tag, names file, then the --member/--meta arguments
    local tag=$1 names=$2
    shift 2
    "$PACK" conda-set --names "$names" --name-prefix komira_ --meta-name-file "$META_NAME_FILE" --mojo-pin "$pin" \
        --external __linux --external mojo-compiler "$@" --out-dir "$W/out_$tag" > "$W/set_$tag.log" 2>&1
}
members() { # every member except those named: <manifest>=<file> pairs
    local n skip=" $* "
    for n in $NAMES; do
        case "$skip" in *" $n "*) continue ;; esac
        printf -- '--member\n%s\n' "$K/m/$n.manifest.json=$K/set/$n.conda"
    done
}
refuse() { # name, required text, tag
    if grep -qF -- "$2" "$W/set_$3.log"; then pass "$1"; else fail "$1: no '$2' (see $W/set_$3.log)"; fi
}
META_PAIR="$K/m/$META.manifest.json=$K/set/$META.conda"
mapfile -t good < <(members)
if setrun good "$TN" "${good[@]}" --meta "$META_PAIR" && [ -f "$W/out_good/release_set.json" ] && cmp -s "$W/out_good/release_set.json" "$SET"; then
    pass "controls: the good members and metapackage give a set identical to the build's (same release_set.json)"
else
    fail "controls: the unmodified set is not accepted by komira_pack conda-set (see $W/set_good.log)"
fi

first=$(echo "$NAMES" | head -n 1)
last=$(echo "$NAMES" | tail -n 1)
# missing member
mapfile -t some < <(members "$last")
setrun missing "$TN" "${some[@]}" --meta "$META_PAIR" && fail "missing member accepted"
refuse refuse_missing_member "missing member: \`$last\` is approved but no package for it is in the set" missing
if [ ! -e "$W/out_missing" ]; then pass "refusals: a refused set writes no directory"; else fail "refusals: a refused set left $W/out_missing"; fi

# a member not on the list (the list is shorter than the set)
grep -v "^$first	" "$TN" > "$W/short.tsv"
setrun extra "$W/short.tsv" "${good[@]}" --meta "$META_PAIR" && fail "a member off the list accepted"
refuse refuse_unlisted_member "\`$first\` is in the set but not on the approved list" extra

# version skew: one library repacked with another stamp
pack_member() { # name stamp names-file out-prefix [extra komira_pack args]
    local n=$1 st=$2 names=$3 o=$4
    shift 4
    "$PACK" conda --name "$n" --name-prefix komira_ --names "$names" --version-prefix packaging/conda/VERSION_PREFIX \
        --stamp "$st" --timestamp-ms 86400000 --commit "$C40" --subdir linux-64 --mojo-pin "$pin" --license Apache-2.0 \
        --summary s --home https://github.com/komira-ai/komira --payload "$(out_of "//src/$n:$n")" --sources "$(out_of "//src/${n}:${n}[src]")" \
        --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label "x//$n" \
        --out "$o.conda" --conda-manifest "$o.manifest.json" --digest "$o.digest" "$@" 2> "$o.err"
}
skewed=komira_clock
pack_member $skewed 8 "$TN" "$W/skew" || fail "skew: cannot repack $skewed (see $W/skew.err)"
mapfile -t others < <(members $skewed)
setrun skew "$TN" "${others[@]}" --member "$W/skew.manifest.json=$W/skew.conda" --meta "$META_PAIR" && fail "version skew accepted"
refuse refuse_version_skew "version skew: \`$skewed\` is $(tr -d ' \t\r\n' < packaging/conda/VERSION_PREFIX).8, the metapackage is $VERSION" skew

# a dependency outside the set: a package built against a longer list, with a dependency on its extra name
{ cat "$TN"; printf 'komira_zzz_extra\t//src/komira_zzz_extra:komira_zzz_extra\tx\n'; } > "$W/more.tsv"
outside=komira_name_registry
pack_member $outside 7 "$W/more.tsv" "$W/outside" --dep komira_hash --dep komira_zzz_extra || fail "outside: cannot pack $outside (see $W/outside.err)"
mapfile -t others < <(members $outside)
setrun outside "$TN" "${others[@]}" --member "$W/outside.manifest.json=$W/outside.conda" --meta "$META_PAIR" && fail "a dependency outside the set accepted"
refuse refuse_dependency_outside_the_set "\`$outside\` requires \`komira_zzz_extra\`, which is outside the release set" outside

# a manifest that disagrees with its file, and a file changed after the manifest
jq '.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$K/m/$first.manifest.json" > "$W/tampered.manifest.json"
mapfile -t others < <(members "$first")
setrun manifest "$TN" "${others[@]}" --member "$W/tampered.manifest.json=$K/set/$first.conda" --meta "$META_PAIR" && fail "a wrong manifest sha256 accepted"
refuse refuse_manifest_sha "$first: the manifest's sha256 is not the file's" manifest
cp "$K/set/$first.conda" "$W/flipped.conda" && printf 'Z' | dd of="$W/flipped.conda" bs=1 seek=200 conv=notrunc 2> /dev/null
setrun flipped "$TN" "${others[@]}" --member "$K/m/$first.manifest.json=$W/flipped.conda" --meta "$META_PAIR" && fail "a changed file accepted"
if grep -qE 'sha256 is not the file|crc|zstd|zip|corrupt|tar' "$W/set_flipped.log"; then pass "refuse_changed_file"; else fail "refuse_changed_file: see $W/set_flipped.log"; fi

# a metapackage that pins fewer libraries (built from a shorter list)
meta_pack() { # names-file meta-name-file out-prefix
    "$PACK" conda-meta --names "$1" --name-prefix komira_ --meta-name-file "$2" --version-prefix packaging/conda/VERSION_PREFIX \
        --stamp 7 --timestamp-ms 86400000 --commit "$C40" --subdir linux-64 --license Apache-2.0 --summary s \
        --home https://github.com/komira-ai/komira --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" --label x//meta \
        --out "$3.conda" --conda-manifest "$3.manifest.json" --digest "$3.digest" 2> "$3.err"
}
meta_pack "$W/short.tsv" "$META_NAME_FILE" "$W/shortmeta" || fail "cannot build the short metapackage (see $W/shortmeta.err)"
setrun shortmeta "$TN" "${good[@]}" --meta "$W/shortmeta.manifest.json=$W/shortmeta.conda" && fail "a metapackage of a shorter list accepted"
refuse refuse_short_metapackage "the metapackage's requirements are not exactly the guard and every approved library at $VERSION" shortmeta
refuse refuse_short_metapackage_list "\`$META\` was built against another approved list" shortmeta
if "$PACK" conda-meta-check --package "$W/shortmeta.conda" --conda-manifest "$W/shortmeta.manifest.json" --names "$TN" --name-prefix komira_ \
    --meta-name-file "$META_NAME_FILE" --expect-subdir linux-64 --out "$W/mc.marker" 2> "$W/mc.err"; then
    fail "conda-meta-check accepted a metapackage of another list"
elif grep -q 'metapackage depends is not the guard and every' "$W/mc.err"; then pass "refuse_meta_check_other_list"; else fail "refuse_meta_check_other_list: see $W/mc.err"; fi
if "$PACK" conda-meta-check --package "$K/set/$META.conda" --conda-manifest "$K/m/$META.manifest.json" --names "$TN" --name-prefix komira_ \
    --meta-name-file "$META_NAME_FILE" --expect-subdir linux-64 --require-stamped true --out "$W/mc_ok.marker" 2> "$W/mc_ok.err"; then
    pass "controls: conda-meta-check accepts the real metapackage as a release"
else
    fail "controls: conda-meta-check refused the real metapackage (see $W/mc_ok.err)"
fi

# a metapackage named like a library, or like a listed one
printf 'komira_metapackage\n' > "$W/prefixed_name"
meta_pack "$TN" "$W/prefixed_name" "$W/prefixed" && fail "a metapackage named with the library prefix was built"
if grep -q 'carries the library prefix' "$W/prefixed.err"; then pass "refuse_meta_name_prefix"; else fail "refuse_meta_name_prefix: see $W/prefixed.err"; fi
printf '%s\n' "$first" > "$W/listed_name"
meta_pack "$TN" "$W/listed_name" "$W/listed" && fail "a metapackage named as a library was built"
if grep -q 'is also a library on the approved list' "$W/listed.err"; then pass "refuse_meta_name_listed"; else fail "refuse_meta_name_listed: see $W/listed.err"; fi

# ---- uncached -----------------------------------------------------------------
if [ "$uncached" = 1 ]; then
    problems=""
    for n in 1 2; do
        # shellcheck disable=SC2086
        timeout 3000 "$BUCK2" --isolation-dir komira_tests_conda_set build --no-remote-cache $STAMP "$T:release_set" --materializations all --show-full-output \
            > "$W/uncached_$n.out" 2> "$W/uncached_$n.log"
        rc=$?
        "$BUCK2" --isolation-dir komira_tests_conda_set kill > /dev/null 2>&1
        if [ "$rc" != 0 ]; then
            problems="$problems build-$n-failed"
        else
            d=$(sed -n 's/^[^ ]* //p' "$W/uncached_$n.out" | tail -n 1)
            (cd "$d" && sha256sum -- * | sort -k2) > "$W/sha_$n.txt"
            if [ "${KOMIRA_CHECKS_MODE:-remote}" = local ]; then ran='Commands: [0-9]+ \(cached: 0, remote: 0, local: [1-9]'; else ran='Commands: [0-9]+ \(cached: 0, remote: [1-9]'; fi
            grep -qE "$ran" "$W/uncached_$n.log" || problems="$problems build-$n-did-not-execute"
        fi
    done
    if [ -z "$problems" ] && ! cmp -s "$W/sha_1.txt" "$W/sha_2.txt"; then
        problems=" differ: $(diff "$W/sha_1.txt" "$W/sha_2.txt" | head -n 4 | tr '\n' ' ')"
    fi
    if [ -z "$problems" ] && [ "$(wc -l < "$W/sha_1.txt" | tr -d ' ')" != "$((COUNT + 2))" ]; then problems=" the set directory did not hold $((COUNT + 2)) files"; fi
    if [ -n "$problems" ]; then fail "uncached:$problems (see $W)"; else
        pass "uncached: two uncached builds in two fresh daemons give the same sha256 for all $((COUNT + 2)) files of the set ($(grep -oE 'Commands: [0-9]+' "$W/uncached_1.log" | head -n 1) actions each, none cached); release_set.json $(grep ' release_set.json' "$W/sha_1.txt" | cut -c1-16)..."
    fi
else
    echo "SKIP  conda_set uncached (--no-uncached)"
fi

# ---- install ------------------------------------------------------------------
if [ "$install" = 1 ] && command -v pixi > /dev/null && curl -fsSL -o /dev/null -I https://conda.modular.com/max/linux-64/repodata.json 2> /dev/null; then
    C="$W/channel"
    mkdir -p "$C/linux-64" "$C/noarch" "$W/with" "$W/without"
    entries='{}'
    for n in $NAMES $META; do
        f="$K/set/$n.conda"
        fn="$n-$VERSION-0.conda"
        cp "$f" "$C/linux-64/$fn"
        unzip -p "$f" 'info-*' | zstd -dc | tar -xO -f - info/index.json > "$W/index_$n.json"
        entries=$(jq -c --arg fn "$fn" --slurpfile i "$W/index_$n.json" --arg s "$(sha256sum < "$f" | cut -c1-64)" --argjson z "$(stat -L -c %s "$f")" \
            '. + {($fn): ($i[0] + {sha256: $s, size: $z})}' <<< "$entries")
    done
    jq -n --argjson e "$entries" '{info: {subdir: "linux-64"}, packages: {}, "packages.conda": $e, removed: [], repodata_version: 1}' > "$C/linux-64/repodata.json"
    jq -n '{info: {subdir: "noarch"}, packages: {}, "packages.conda": {}, removed: [], repodata_version: 1}' > "$C/noarch/repodata.json"
    cat > "$W/hello.mojo" << 'EOM'
from komira_encoding import hex_encode
from komira_hash import fnv1a_64


def main():
    var data = List[UInt8]()
    data.append(0xDE)
    data.append(0xAD)
    data.append(0xBE)
    data.append(0xEF)
    print(hex_encode(data))
    print(fnv1a_64(String("a").as_bytes()))
EOM
    for variant in with without; do
        {
            printf '[workspace]\nname = "komira-conda-set-test"\nchannels = ["file://%s", "https://conda.modular.com/max", "conda-forge"]\nplatforms = ["linux-64"]\n\n[dependencies]\n' "$C"
            if [ "$variant" = with ]; then printf '%s = "==%s"\n' "$META" "$VERSION"; else printf 'mojo-compiler = "==%s"\n' "$pin"; fi
        } > "$W/$variant/pixi.toml"
        cp "$W/hello.mojo" "$W/$variant/hello.mojo"
    done
    export PIXI_CACHE_DIR="$W/pixi_cache" PIXI_HOME="$W/pixi_home"
    problems=""
    pixi install --manifest-path "$W/with/pixi.toml" > "$W/install_with.log" 2>&1 || problems="$problems install-failed"
    if [ -z "$problems" ]; then
        for n in $NAMES; do
            cmp -s "$W/with/.pixi/envs/default/lib/mojo/$n.mojoc" <(unzip -p "$K/set/$n.conda" 'pkg-*' | zstd -dc | tar -xO -f - "lib/mojo/$n.mojoc") || problems="$problems $n-not-installed-as-built"
        done
        grep -q "$META-$VERSION-0.conda" "$W/with/pixi.lock" || problems="$problems lock-lacks-the-metapackage"
        got=$(cd "$W/with" && timeout 600 pixi run --manifest-path "$W/with/pixi.toml" mojo run hello.mojo 2> "$W/run_with.err")
        [ "$got" = "$(printf 'deadbeef\n12638187200555641996')" ] || problems="$problems program-output:[$got]"
    fi
    pixi install --manifest-path "$W/without/pixi.toml" > "$W/install_without.log" 2>&1 || problems="$problems control-install-failed"
    if (cd "$W/without" && timeout 600 pixi run --manifest-path "$W/without/pixi.toml" mojo run hello.mojo > "$W/run_without.out" 2>&1); then
        problems="$problems control-imported-without-the-metapackage"
    elif ! grep -qF "komira_encoding" "$W/run_without.out"; then
        problems="$problems control-failed-for-another-reason"
    fi
    if [ -n "$problems" ]; then fail "install:$problems (see $W)"; else
        pass "install: pixi installs only '$META ==$VERSION' from a file:// channel of the set, the solver brings all $COUNT libraries (each .mojoc installed as built) and mojo-compiler ==$pin, and a program importing komira_encoding and komira_hash prints deadbeef and 12638187200555641996; the same project without the metapackage cannot import"
    fi
else
    echo "SKIP  conda_set install ($([ "$install" = 1 ] || echo '--no-install'; command -v pixi > /dev/null || echo 'no pixi'))"
fi

if [ "$fails" = 0 ] && [ -z "${KOMIRA_TEST_KEEP:-}" ]; then rm -r -f "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
