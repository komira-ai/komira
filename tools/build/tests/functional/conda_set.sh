#!/usr/bin/env bash
# conda_set.sh -- tests of the SET of conda packages: what the release tool does with the
# packages the build makes. Every library under //src has a package target (the mojo_library
# macro declares it); the release tool lists which it publishes, builds each one's [release],
# and gives their manifests to `komira_pack conda-meta`, which makes the metapackage. This
# script plays that tool, on the packages the repository really builds.
#
# usage: tools/build/tests/functional/conda_set.sh [--no-uncached] [--no-install]   (from anywhere; BUCK2 overrides;
#        KOMIRA_TEST_KEEP=1 keeps the scratch directory, with every log, after a pass)
#
#   enumerate  tools/build/package/list_conda_targets.sh prints a package target for every library
#              of //src with no declaration anywhere; every one of them builds (a refusal is a
#              value, not a build failure), and the libraries that cannot be packaged say why
#              (komira_core: native code). The rest are the set the later checks use.
#   contract   the manifest of every package of the set, and of the metapackage, is read by
#              kci's own parser (src/kci_artifact_manifest, run as the probe
#              //tools/build/package/manifest_probe:parse_manifest) and rendered again by kci's
#              writer: the bytes are identical. The same probe refuses a manifest that points at
#              its metadata, so it is not a probe that accepts anything.
#   metapackage `komira_pack conda-meta` over the members' manifests gives a package with no
#              file whose requirements are exactly the platform guard and every member at its own
#              version (no compiler pin: the members carry it); the same inputs give the same
#              bytes; `conda-check --kind metapackage` accepts it, as a release too.
#   refusals   conda-meta refuses, naming it: version skew between members, a member twice, a member
#              whose file is not its manifest's sha256, a member that is a refused package (no
#              manifest), a name that is also a member, a name that is not a conda name, no members.
#              conda-check refuses a metapackage checked against a shorter or longer member list,
#              against the wrong kind, an unstamped one as a release, a manifest with an extra key.
#   uncached   two builds in two fresh daemons with --no-remote-cache, one isolation directory,
#              give the same sha256 for every file of every package of the set, and the
#              metapackage made from each run's manifests is the same file (skipped with
#              --no-uncached).
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

C40=0123456789abcdef0123456789abcdef01234567
STAMP="-c komira.package_stamp=7 -c komira.package_commit=$C40 -c komira.package_timestamp_ms=86400000"
STAMP8="-c komira.package_stamp=8 -c komira.package_commit=$C40 -c komira.package_timestamp_ms=86400000"
META=komira
pin=$(sed -n 's/^MOJO_COMPILER_PIN = "\(.*\)"$/\1/p' tools/build/package/conda.bzl)

# ---- enumerate ------------------------------------------------------------
TARGETS=()
while IFS= read -r t; do [ -n "$t" ] && TARGETS+=("$t"); done < <(tools/build/package/list_conda_targets.sh //src/... //tools/build/mojo/runtime_paths/... 2> "$W/list.err")
if [ "${#TARGETS[@]}" -lt 2 ]; then
    fail "enumerate: list_conda_targets.sh printed ${#TARGETS[@]} targets (see $W/list.err)"
    echo "logs: $W"
    exit 1
fi
# shellcheck disable=SC2086
if ! "$BUCK2" build "${TARGETS[@]}" --materializations all --show-full-output > "$W/all.out" 2> "$W/all.log"; then
    fail "enumerate: building every package target of //src failed, but a refusal is a value and not a build failure (see $W/all.log)"
    echo "logs: $W"
    exit 1
fi
K="$W/keep"
mkdir -p "$K/dev"
OK=() REFUSED=()
declare -A TGT
while read -r target path; do
    name=${target##*:}
    name=${name%_conda}
    TGT[$name]=$target
    cp -r -L "$path" "$K/dev/$name" && chmod -R u+w "$K/dev/$name"
    if [ -f "$K/dev/$name/REFUSED" ]; then REFUSED+=("$name"); else OK+=("$name"); fi
done < "$W/all.out"
problems=""
[ "$((${#OK[@]} + ${#REFUSED[@]}))" = "${#TARGETS[@]}" ] || problems="$problems targets-without-output"
printf '%s\n' "${REFUSED[@]}" | grep -qx komira_core || problems="$problems komira_core-not-refused"
grep -q 'links native code' "$K/dev/komira_core/REFUSED" 2> /dev/null || problems="$problems komira_core-reason:[$(cat "$K/dev/komira_core/REFUSED" 2> /dev/null)]"
printf '%s\n' "${OK[@]}" | grep -qx komira_encoding || problems="$problems komira_encoding-refused"
for r in "${REFUSED[@]}"; do [ -s "$K/dev/$r/REFUSED" ] || problems="$problems $r-has-no-reason"; done
if [ -n "$problems" ]; then fail "enumerate:$problems (see $W)"; else
    pass "enumerate: ${#TARGETS[@]} package targets, one per library of //src (and of komira_runtime_paths, which a package requires), none declared anywhere; all build; ${#REFUSED[@]} are refused with a reason (komira_core: native code) and ${#OK[@]} make a package"
fi

# The release tool's completeness rule, played here: every requirement of a package of the set is
# another package of the set (or the platform guard or the compiler). A package that requires a
# library which was refused, or which nobody lists, cannot be installed; the build cannot see the
# second case (it does not know the list) and sees the first only when the reason is known without
# reading sources, so the release tool must check this over its declarations.
problems=""
for n in "${OK[@]}"; do
    for req in $(jq -r '.depends[2:][] | split(" ")[0]' "$K/dev/$n/metadata.json"); do
        printf '%s\n' "${OK[@]}" | grep -qx "$req" || problems="$problems $n-requires-$req"
    done
done
if [ -n "$problems" ]; then fail "closure:$problems (a package requires one that is not in the set)"; else
    pass "closure: every requirement of each of the ${#OK[@]} packages is another package of the set"
fi

# ---- the stamped set --------------------------------------------------------
build_release() { # buck2 args..., names in OK -> the release directories under $1 (a directory to fill)
    local dest=$1
    shift
    local ts=()
    for n in "${OK[@]}"; do ts+=("${TGT[$n]}[release]"); done
    "$BUCK2" "$@" "${ts[@]}" --materializations all --show-full-output 2> "$dest.log" | while read -r target path; do
        n=${target##*:}
        n=${n%_conda\[release\]}
        mkdir -p "$dest" && cp -r -L "$path" "$dest/$n" && chmod -R u+w "$dest/$n"
    done
}
# shellcheck disable=SC2086
build_release "$K/rel" build $STAMP
MAN=()
for n in "${OK[@]}"; do MAN+=("$K/rel/$n/manifest.json"); done
VERSION=$(jq -r .version "$K/rel/${OK[0]}/manifest.json")
problems=""
for n in "${OK[@]}"; do
    [ -f "$K/rel/$n/manifest.json" ] || { problems="$problems $n-has-no-release"; continue; }
    jq -e --arg v "$VERSION" '.version == $v' "$K/rel/$n/manifest.json" > /dev/null || problems="$problems $n-version"
    jq -e --arg c "$C40" '.stamped == true and .source_commit == $c' "$K/rel/$n/metadata.json" > /dev/null || problems="$problems $n-stamp"
done
for r in "${REFUSED[@]}"; do
    # shellcheck disable=SC2086
    if "$BUCK2" build $STAMP "${TGT[$r]}[release]" > "$W/rel_$r.log" 2>&1; then problems="$problems refused-$r-has-a-release"; fi
done
if [ -n "$problems" ]; then fail "release:$problems (see $W)"; else
    pass "release: stamped build $VERSION gives a [release] directory for each of the ${#OK[@]} packages (one version, source commit and commit time across the set), and none for the ${#REFUSED[@]} refused libraries"
fi

# ---- the metapackage ------------------------------------------------------
PACK=$("$BUCK2" build //tools/build/package:komira_pack --show-full-output 2> /dev/null | sed -n 's/^[^ ]* //p' | tail -n 1)
meta() { # out-dir, name, then --member-manifest args or other flags
    local o=$1 name=$2
    shift 2
    "$PACK" conda-meta --name "$name" --license Apache-2.0 --summary "komira $VERSION: every library, at one version" \
        --home https://github.com/komira-ai/komira --extra-file "info/licenses/LICENSE=$ROOT/LICENSE" \
        --label "komira//tools/build/package:komira_pack conda-meta" --out-dir "$o" "$@"
}
members() { for m in "$@"; do printf -- '--member-manifest\n%s\n' "$m"; done; }
mcheck() { # dir, then member manifests... (checked as the metapackage `komira`); extra args after `--`
    local d=$1
    shift
    local ms=() extra=() seen=0 a
    for a in "$@"; do
        if [ "$a" = -- ]; then seen=1; elif [ "$seen" = 1 ]; then extra+=("$a"); else ms+=(--member-manifest "$a"); fi
    done
    "$PACK" conda-check --dir "$d" --kind metapackage --name "$META" --expect-subdir linux-64 "${ms[@]}" --out "$W/mcheck.marker" ${extra[@]+"${extra[@]}"}
}
problems=""
# shellcheck disable=SC2046
meta "$K/meta1" "$META" $(members "${MAN[@]}") 2> "$W/meta1.err" || problems="$problems meta1-failed"
# shellcheck disable=SC2046
meta "$K/meta2" "$META" $(members "${MAN[@]}") 2> "$W/meta2.err" || problems="$problems meta2-failed"
if [ -z "$problems" ]; then
    MF="$META-$VERSION-0.conda"
    [ "$(ls "$K/meta1" | tr '\n' ' ')" = "$MF manifest.json metadata.json " ] || problems="$problems directory:[$(ls "$K/meta1" | tr '\n' ' ')]"
    cmp -s "$K/meta1/$MF" "$K/meta2/$MF" || problems="$problems two-runs-differ"
    cmp -s "$K/meta1/manifest.json" "$K/meta2/manifest.json" || problems="$problems manifests-differ"
    mcheck "$K/meta1" "${MAN[@]}" 2> "$W/mcheck_ok.err" || problems="$problems check-refused-the-metapackage"
    mcheck "$K/meta1" "${MAN[@]}" -- --require-stamped true 2> "$W/mcheck_rel.err" || problems="$problems check-refused-it-as-a-release"
    # read with tools that are not the writer's: the requirements are the guard and every member, and it holds no file
    want=$(for n in "${OK[@]}"; do printf '%s ==%s\n' "$n" "$VERSION"; done | LC_ALL=C sort)
    got=$(unzip -p "$K/meta1/$MF" 'info-*' | zstd -dc | tar -xO -f - info/index.json | jq -r '.depends[]' | tail -n +2)
    [ "$got" = "$want" ] || problems="$problems requirements:[$got]"
    [ "$(unzip -p "$K/meta1/$MF" 'info-*' | zstd -dc | tar -xO -f - info/index.json | jq -r '.depends[0]')" = __linux ] || problems="$problems guard"
    unzip -p "$K/meta1/$MF" 'info-*' | zstd -dc | tar -xO -f - info/index.json | jq -e '.name == "komira" and .version == "'"$VERSION"'" and .timestamp == 86400000 and (.depends | map(startswith("mojo-compiler")) | any | not)' > /dev/null || problems="$problems index"
    [ -z "$(unzip -p "$K/meta1/$MF" 'pkg-*' | zstd -dc | tar -tf -)" ] || problems="$problems holds-a-file"
    jq -e --argjson n "${#OK[@]}" '.kind == "metapackage" and (.members | length) == $n and .stamped == true and .source_commit == "'"$C40"'"' "$K/meta1/metadata.json" > /dev/null || problems="$problems metadata"
fi
if [ -n "$problems" ]; then fail "metapackage:$problems (see $W)"; else
    pass "metapackage: conda-meta over ${#OK[@]} member manifests gives $MF with no file, requiring exactly the platform guard and every member at $VERSION (no compiler pin); the same inputs give the same bytes; conda-check accepts it, as a release too"
fi

# ---- contract: kci's own parser reads what the build emits -----------------
PROBE=$("$BUCK2" build //tools/build/package/manifest_probe:parse_manifest 2> "$W/probe_build.log" && "$BUCK2" run //tools/build/package/manifest_probe:parse_manifest -- "${MAN[@]}" "$K/meta1/manifest.json" 2> "$W/probe.err")
problems=""
lines=$(printf '%s\n' "$PROBE" | grep -c '^OK CONDA ')
[ "$lines" = "$((${#OK[@]} + 1))" ] || problems="$problems read-$lines-of-$((${#OK[@]} + 1))"
printf '%s\n' "$PROBE" | grep -v '^OK CONDA .* render-identical=yes$' | grep -q . && problems="$problems not-rendered-identically-or-refused:[$(printf '%s\n' "$PROBE" | grep -v '^OK CONDA .* render-identical=yes$' | head -n 2)]"
printf '%s\n' "$PROBE" | grep -q "^OK CONDA $META $VERSION linux-64 $MF " || problems="$problems metapackage-line"
cp "$K/meta1/manifest.json" "$W/with_metadata.json" && sed -i 's/}$/,"metadata":"metadata.json"}/' "$W/with_metadata.json"
"$BUCK2" run //tools/build/package/manifest_probe:parse_manifest -- "$W/with_metadata.json" > "$W/probe_neg.out" 2>&1 && problems="$problems probe-accepted-a-metadata-key"
grep -q "'metadata' belongs to a PYTHON artifact" "$W/probe_neg.out" || problems="$problems probe-negative-text"
if [ -n "$problems" ]; then fail "contract:$problems (see $W)"; else
    pass "contract: kci's artifact-manifest parser reads the manifests of all ${#OK[@]} packages and of the metapackage, and kci's writer renders each one back to the same bytes; the same probe refuses a manifest with a \`metadata\` key (so it can fail)"
fi

# ---- refusals -------------------------------------------------------------
refuse() { # name, text, then the conda-meta arguments (after the name and out dir)
    local name=$1 text=$2
    shift 2
    if meta "$W/ref_$name" "$@" 2> "$W/ref_$name.err"; then fail "refuse_$name: conda-meta accepted it"
    elif grep -qF -- "$text" "$W/ref_$name.err"; then pass "refuse_$name"
    else fail "refuse_$name: refused without '$text' (see $W/ref_$name.err)"; fi
}
# version skew: one member from another stamp
build_release "$K/rel8" build $STAMP8 > /dev/null 2>&1
if [ -f "$K/rel8/${OK[0]}/manifest.json" ]; then
    # shellcheck disable=SC2046
    refuse version_skew "members are not one release" "$META" $(members "$K/rel8/${OK[0]}/manifest.json" "${MAN[@]:1}")
else
    fail "refuse_version_skew: cannot build the second stamp (see $K/rel8.log)"
fi
# shellcheck disable=SC2046
refuse member_twice "given twice" "$META" $(members "${MAN[@]}" "${MAN[0]}")
# a member whose file is not its manifest's sha256
cp -r "$K/rel/${OK[0]}" "$W/tampered" && chmod -R u+w "$W/tampered" && printf 'Z' | dd of="$W/tampered/$(jq -r .file "$W/tampered/manifest.json")" bs=1 seek=200 conv=notrunc 2> /dev/null
# shellcheck disable=SC2046
refuse member_file_changed "the manifest's sha256 is not the file's" "$META" $(members "$W/tampered/manifest.json" "${MAN[@]:1}")
# a refused package has no manifest to pass
if [ "${#REFUSED[@]}" -gt 0 ]; then
    # shellcheck disable=SC2046
    refuse member_refused "cannot read" "$META" $(members "$K/dev/${REFUSED[0]}/manifest.json" "${MAN[@]}")
fi
# shellcheck disable=SC2046
refuse name_is_a_member "is also a member" "${OK[0]}" $(members "${MAN[@]}")
# shellcheck disable=SC2046
refuse name_not_a_conda_name "is not lowercase letters, digits and _" "Komira-X" $(members "${MAN[@]}")
refuse no_members "needs at least one --member-manifest" "$META"
# a member that is not a library (a metapackage as a member)
# shellcheck disable=SC2046
refuse member_is_a_metapackage "is \`metapackage\`, must be \`library\`" "komira_outer" $(members "$K/meta1/manifest.json" "${MAN[@]}")
# conda-check against another member list, kind, stamp or manifest
problems=""
mcheck "$K/meta1" "${MAN[@]:1}" 2> "$W/mc_short.err" && problems="$problems check-accepted-a-shorter-member-list"
grep -q 'index depends has' "$W/mc_short.err" || problems="$problems short-text"
mcheck "$K/meta1" "${MAN[@]}" "$K/rel8/${OK[0]}/manifest.json" 2> "$W/mc_long.err" && problems="$problems check-accepted-a-longer-member-list"
"$PACK" conda-check --dir "$K/meta1" --kind library --name "$META" --expect-subdir linux-64 --import-name x --mojo-pin "$pin" --payload "$K/rel/${OK[0]}/${OK[0]}-$VERSION-0.conda" --out "$W/mcheck.marker" 2> "$W/mc_kind.err" && problems="$problems check-accepted-the-wrong-kind"
cp -r "$K/meta1" "$W/meta_x" && chmod -R u+w "$W/meta_x" && jq -c '. + {metadata: "metadata.json"}' "$K/meta1/manifest.json" > "$W/meta_x/manifest.json"
mcheck "$W/meta_x" "${MAN[@]}" 2> "$W/mc_extra.err" && problems="$problems check-accepted-an-extra-key"
# an unstamped metapackage (members built unstamped) is no release
UN=()
for n in "${OK[@]}"; do UN+=("$K/dev/$n/manifest.json"); done
# shellcheck disable=SC2046
meta "$W/meta_un" "$META" $(members "${UN[@]}") 2> "$W/meta_un.err" || problems="$problems unstamped-meta-failed"
mcheck "$W/meta_un" "${UN[@]}" 2> "$W/mc_un_ok.err" || problems="$problems unstamped-meta-check"
mcheck "$W/meta_un" "${UN[@]}" -- --require-stamped true 2> "$W/mc_un.err" && problems="$problems check-accepted-an-unstamped-metapackage-as-a-release"
grep -q 'never stamped' "$W/mc_un.err" || problems="$problems unstamped-text"
if [ -n "$problems" ]; then fail "refusals: conda-check:$problems (see $W)"; else
    pass "refusals: conda-check refuses a metapackage checked against a shorter or longer member list, the wrong kind, an extra manifest key, and an unstamped one as a release; accepts it unstamped as a development file"
fi

# ---- uncached ---------------------------------------------------------------
# Two builds in two fresh daemons with --no-remote-cache, one after the other in ONE
# isolation directory (a `.mojoc` records the path of its sources, which has the
# isolation directory's name in it).
if [ "$uncached" = 1 ]; then
    problems=""
    for n in 1 2; do
        ts=()
        for l in "${OK[@]}"; do ts+=("${TGT[$l]}[release]"); done
        # shellcheck disable=SC2086
        timeout 3000 "$BUCK2" --isolation-dir komira_tests_conda_set build --no-remote-cache $STAMP "${ts[@]}" --materializations all --show-full-output \
            > "$W/uncached_$n.out" 2> "$W/uncached_$n.log"
        rc=$?
        "$BUCK2" --isolation-dir komira_tests_conda_set kill > /dev/null 2>&1
        if [ "$rc" != 0 ]; then
            problems="$problems build-$n-failed"
            continue
        fi
        mkdir -p "$W/u$n"
        : > "$W/sha_$n.txt"
        ms=()
        while read -r target path; do
            l=${target##*:}
            l=${l%_conda\[release\]}
            mkdir -p "$W/u$n/$l" && cp -r -L "$path/." "$W/u$n/$l/"
            (cd "$W/u$n/$l" && sha256sum -- * | sed "s#  #  $l/#") >> "$W/sha_$n.txt"
            ms+=("$W/u$n/$l/manifest.json")
        done < "$W/uncached_$n.out"
        sort -o "$W/sha_$n.txt" "$W/sha_$n.txt"
        # shellcheck disable=SC2046
        meta "$W/umeta$n" "$META" $(members "${ms[@]}") 2> "$W/umeta$n.err" || problems="$problems meta-$n-failed"
        (cd "$W/umeta$n" && sha256sum -- * | sed "s#  #  $META/#") >> "$W/sha_$n.txt"
        if [ "${KOMIRA_CHECKS_MODE:-remote}" = local ]; then ran='Commands: [0-9]+ \(cached: 0, remote: 0, local: [1-9]'; else ran='Commands: [0-9]+ \(cached: 0, remote: [1-9]'; fi
        grep -qE "$ran" "$W/uncached_$n.log" || problems="$problems build-$n-did-not-execute"
    done
    if [ -z "$problems" ] && ! cmp -s "$W/sha_1.txt" "$W/sha_2.txt"; then
        problems=" differ: $(diff "$W/sha_1.txt" "$W/sha_2.txt" | head -n 4 | tr '\n' ' ')"
    fi
    if [ -z "$problems" ] && [ "$(wc -l < "$W/sha_1.txt" | tr -d ' ')" != "$((3 * ${#OK[@]} + 3))" ]; then problems=" the sets did not hold $((3 * ${#OK[@]} + 3)) files"; fi
    if [ -n "$problems" ]; then fail "uncached:$problems (see $W)"; else
        pass "uncached: two uncached builds in two fresh daemons give the same sha256 for all $((3 * ${#OK[@]} + 3)) files of the ${#OK[@]} packages and of the metapackage made from each run's manifests ($(grep -oE 'Commands: [0-9]+' "$W/uncached_1.log" | head -n 1) actions each, none cached)"
    fi
else
    echo "SKIP  conda_set uncached (--no-uncached)"
fi

# ---- install ------------------------------------------------------------------
if [ "$install" = 1 ] && command -v pixi > /dev/null && curl -fsSL -o /dev/null -I https://conda.modular.com/max/linux-64/repodata.json 2> /dev/null; then
    C="$W/channel"
    mkdir -p "$C/linux-64" "$C/noarch" "$W/with" "$W/without"
    entries='{}'
    for dir in "${OK[@]/#/$K/rel/}" "$K/meta1"; do
        fn=$(jq -r .file "$dir/manifest.json")
        f="$dir/$fn"
        cp "$f" "$C/linux-64/$fn"
        unzip -p "$f" 'info-*' | zstd -dc | tar -xO -f - info/index.json > "$W/index.json"
        entries=$(jq -c --arg fn "$fn" --slurpfile i "$W/index.json" --arg s "$(sha256sum < "$f" | cut -c1-64)" --argjson z "$(stat -L -c %s "$f")" \
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
        for n in "${OK[@]}"; do
            cmp -s "$W/with/.pixi/envs/default/lib/mojo/$n.mojoc" <(unzip -p "$K/rel/$n/$n-$VERSION-0.conda" 'pkg-*' | zstd -dc | tar -xO -f - "lib/mojo/$n.mojoc") || problems="$problems $n-not-installed-as-built"
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
        pass "install: pixi installs only '$META ==$VERSION' from a file:// channel of the set, the solver brings all ${#OK[@]} libraries (each .mojoc installed as built) and mojo-compiler ==$pin, and a program importing komira_encoding and komira_hash prints deadbeef and 12638187200555641996; the same project without the metapackage cannot import"
    fi
else
    echo "SKIP  conda_set install ($([ "$install" = 1 ] || echo '--no-install'; command -v pixi > /dev/null || echo 'no pixi'))"
fi

if [ "$fails" = 0 ] && [ -z "${KOMIRA_TEST_KEEP:-}" ]; then rm -r -f "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
