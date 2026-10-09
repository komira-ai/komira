#!/usr/bin/env bash
# tools/build/tests/functional/darwin/check.sh -- the macOS arm64 target and execution platform.
#
# usage: tools/build/tests/functional/darwin/check.sh <log_dir>   (from the repo root; BUCK2 names
#        the buck2 binary). Prints PASS/FAIL lines; exits 1 if any failed.
#
# Sections 1-6 need no macOS worker; 7 runs on the macOS workers when the root
# cell configures them, and is SKIPped otherwise. What runs where:
#   1. Unset `[komira_re] darwin_arm64_properties`: no macOS platform is
#      registered, and a darwin-arm64 Mojo target fails to configure (naming
#      the macos constraint) while the linux target still resolves to
#      linux-x86_64.
#   2. Set (a placeholder, resolution only, nothing is built): darwin-arm64
#      Mojo targets resolve to the darwin-arm64 execution platform, the
#      darwin toolchain's unpacking to linux-x86_64, linux targets are
#      unchanged; a property
#      set with no `[komira_re] darwin_macos_hosts`, or equal to a linux set,
#      is refused at load, and so (tests//functional/darwin:BUCK, cases.bzl) are an
#      empty set and malformed host identities. Unset, a wildcard over
#      tools/build/toolchains/darwin skips the darwin-only targets.
#   3. The darwin compile command lines (aquery): the macOS wrapper and
#      busybox, the osx-arm64 compiler closure, --target-cpu apple-m1, the
#      deployment target, no zig, no absolute path.
#   4. The linux actions are the same with and without the darwin key.
#   5. The osx-arm64 closure, unpacked and cut on the farm (linux
#      actions): its Mach-O load commands, read by tools/build/inspect (`inspect macho`), and the
#      DYLD scripts are the shared scripts behind dyld_prelude.sh.
#   6. The macOS scripts, run on this machine against stand-ins: busybox.sh
#      (applets only from /bin and /usr/bin, anything else refused), the cc
#      shim (run paths replaced by the wrapper's, link tail appended),
#      host_identity.sh (every field in the digest; an unreadable field
#      refused), the wrapper (incomplete closure, unexpected shared_libs, a
#      shared-lib build, a non-$ORIGIN run path and a host whose identity is
#      not listed are refused, a listed host is accepted; modular.cfg is
#      rendered with the one run path @loader_path/lib), and run_check.sh
#      (clears DYLD_* as well as LD_*), and gate_runner.sh (the test sees
#      DYLD_LIBRARY_PATH although the `env` applet prunes it, as on macOS).
#   7. Live, on the macOS workers (SKIP unless both `[komira_re]
#      darwin_arm64_properties` and `darwin_macos_hosts` are set):
#      every host identity the workers report (tests//functional/darwin:host_census,
#      uncached) is listed; //tools/build/examples:hello and its run check
#      build and pass there, with the configured property set in `buck2 log
#      what-ran`; the binary is an arm64 Mach-O for macOS 11.0 whose only run
#      path is @loader_path/lib and which loads only the runtime library and
#      the system; the mojo_shared_lib examples and their gates, and
#      libgate_ok's welded test, pass there (both start through
#      gate_runner.sh and need DYLD_LIBRARY_PATH); and a compile whose
#      host list names no worker is refused (exit 2) on the worker.

set -u
mkdir -p "$1" && LOG=$(cd "$1" && pwd) || { echo "usage: $0 <log_dir>" >&2; exit 2; }
BUCK2=${BUCK2:-buck2}
export INSPECT_LOG="$LOG/inspect_build.log"
# shellcheck source=tools/build/tests/tool_lib.sh
. tools/build/tests/tool_lib.sh
fails=0
pass() { echo "PASS  darwin: $1"; }
fail() { echo "FAIL  darwin: $1"; fails=$((fails + 1)); }

# ---- readers: JSON and Mach-O through tools/build/inspect (tool_lib.sh) --------
TAB=$(printf '\t')

version_gt() { # a.b.c x.y.z: whether the first is the newer (missing parts are 0)
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit 1 }'
}

compile_verdict() { # aquery --json: the Mojo compile commands use the macOS toolchain
    local rows bad
    rows=$(inspect_tool json "$1" | awk -F '\t' '
        $2 == "category" && NF == 3 { cat[$1] = $3 }
        $2 == "cmd" && NF == 3 { cmd[$1] = $3 }
        $2 == "cmd" && NF == 4 { if ($1 in cmd) cmd[$1] = cmd[$1] " " $4; else cmd[$1] = $4 }
        END {
            for (a in cat)
                if (cat[a] == "mojo_build" || cat[a] == "mojo_build_test" || cat[a] == "mojo_precompile")
                    print cat[a] "\t" cmd[a]
        }') || { echo "cannot read $1"; return 1; }
    bad=$(printf '%s\n' "$rows" | awk -F '\t' '
        NF < 2 { next }
        {
            n = split("darwin/__busybox.sh__/busybox.sh|darwin/__mojo_wrapper.sh__/mojo_wrapper.sh|toolchains/darwin/__mojo_compiler__/|toolchains/darwin/__link__/| 11.0, |--watchdog-idle-secs=300, --watchdog-sample-secs=30, ", need, "|")
            for (i = 1; i <= n; i++) if (index($2, need[i]) == 0) print $1 " lacks \047" need[i] "\047"
            if (index($2, "zig") > 0) print $1 " names zig"
            if ($1 != "mojo_precompile" && index($2, "--target-cpu, apple-m1") == 0) print $1 " does not target apple-m1"
        }' | LC_ALL=C sort -u)
    if ! printf '%s\n' "$rows" | grep -q "^mojo_build$TAB"; then
        bad="no mojo_build action${bad:+
$bad}"
    fi
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad" | paste -sd ';' - | sed 's/;/; /g'
        return 1
    fi
    echo "$(printf '%s\n' "$rows" | grep -c .) compile actions"
}

macho_closure() { # compiler_dir runtime_dir deployment_target
    # The Mach-O files of the osx-arm64 closure: arm64, in CLOSURE_MANIFEST,
    # loading only @rpath/<a runtime library> or the system, @loader_path run
    # paths, @rpath install names, no newer macOS than the target; and the
    # runtime directory is exactly the compiler's lib/*.dylib, byte for byte.
    local compiler=$1 runtime=$2 target=$3 p libs carried name rel want listing kind value extra count=0
    p=$(mktemp "${TMPDIR:-/tmp}/komira_macho.XXXXXX") || return 1
    libs=$(for name in "$compiler"/lib/*.dylib; do [ -e "$name" ] && echo "${name##*/}"; done | LC_ALL=C sort)
    [ -n "$libs" ] || echo "compiler lib/ holds no .dylib" >> "$p"
    carried=$(ls "$runtime" 2> /dev/null | LC_ALL=C sort)
    [ "$carried" = "$libs" ] ||
        echo "runtime directory holds [$(printf '%s\n' "$carried" | paste -sd ' ' -)], the compiler's lib/ [$(printf '%s\n' "$libs" | paste -sd ' ' -)]" >> "$p"
    for name in $libs; do
        if [ -f "$runtime/$name" ] && ! cmp -s "$runtime/$name" "$compiler/lib/$name"; then
            echo "runtime $name differs from the compiler's lib/$name" >> "$p"
        fi
    done
    for rel in bin/mojo $(printf 'lib/%s\n' $libs); do
        count=$((count + 1))
        want=6
        [ "$rel" = bin/mojo ] && want=2
        tr -s ' \t' '\n\n' < "$compiler/CLOSURE_MANIFEST" | grep -qxF "$rel" || echo "$rel is not in CLOSURE_MANIFEST" >> "$p"
        if ! listing=$(inspect_tool macho "$compiler/$rel" 2>&1); then
            echo "$rel: $listing" >> "$p"
            continue
        fi
        while IFS="$TAB" read -r kind value extra; do
            case "$kind" in
            header)
                [ "$value" = 0x100000c ] && [ "$extra" = "$want" ] ||
                    echo "$rel: cputype $value filetype $extra, want arm64 filetype $want" >> "$p" ;;
            load)
                case "$value" in
                /usr/lib/* | /System/Library/*) ;;
                @rpath/*) printf '%s\n' "$libs" | grep -qxF "${value#@rpath/}" ||
                    echo "$rel loads $value: neither a runtime library nor a system library" >> "$p" ;;
                *) echo "$rel loads $value: neither a runtime library nor a system library" >> "$p" ;;
                esac ;;
            id)
                [ "$value" = "@rpath/${rel##*/}" ] || echo "$rel: install name $value, want @rpath/${rel##*/}" >> "$p" ;;
            rpath)
                case "$value" in @loader_path*) ;; *) echo "$rel: run path $value is not @loader_path-relative" >> "$p" ;; esac ;;
            minos)
                if version_gt "$value" "$target"; then
                    echo "$rel requires macOS $value, newer than the deployment target $target" >> "$p"
                fi ;;
            esac
        done <<< "$listing"
    done
    if [ -s "$p" ]; then
        cat "$p"
        rm -f "$p"
        return 1
    fi
    rm -f "$p"
    echo "$count Mach-O files: arm64, loading only @rpath runtime libraries and the system; $(printf '%s\n' "$libs" | grep -c .) runtime libraries carried"
}

report_outputs() { # build report json [sub-target]: the project root, then each output path
    inspect_tool json "$1" | awk -F '\t' -v sub_target="${2:-}" '
        $1 == "project_root" && NF == 2 { root = $2 }
        $1 == "results" && $3 == "configured" && $5 == "outputs" && NF == 8 && (sub_target == "" || $6 == sub_target) { out[++n] = $8 }
        END { print root; for (i = 1; i <= n; i++) print out[i] }'
}

census_verdict() { # build report json, listed host identities
    local rows root seen unlisted never
    rows=$(report_outputs "$1" DEFAULT) || { echo "cannot read $1"; return 1; }
    root=$(printf '%s\n' "$rows" | head -n 1)
    seen=$(printf '%s\n' "$rows" | tail -n +2 | while IFS= read -r path; do
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$root/$path" | paste -sd ' ' -
    done)
    if [ -z "$seen" ]; then
        echo "no census output"
        return 1
    fi
    unlisted=$(comm -23 <(printf '%s\n' "$seen" | LC_ALL=C sort -u) <(printf '%s\n' $2 | LC_ALL=C sort -u) | paste -sd ' ' -)
    if [ -n "$unlisted" ]; then
        echo "workers report host identities not in darwin_macos_hosts: $unlisted"
        return 1
    fi
    never=$(comm -13 <(printf '%s\n' "$seen" | LC_ALL=C sort -u) <(printf '%s\n' $2 | LC_ALL=C sort -u) | paste -sd ' ' -)
    echo "$(printf '%s\n' "$seen" | grep -c .) actions on $(printf '%s\n' "$seen" | LC_ALL=C sort -u | grep -c .) listed host(s) $(printf '%s\n' "$seen" | LC_ALL=C sort -u | paste -sd ' ' -)${never:+; listed but not seen this run: $never}"
}

hello_verdict() { # what-ran json, build report json: hello built and run-checked on macOS
    local mac acts bad rows root exe stdout listing rpaths
    mac=$(props_norm "$MAC_PROPS")
    acts=$(whatran_actions "$1") || { echo "cannot read $1"; return 1; }
    bad=$(printf '%s\n' "$acts" | awk -F '\t' -v M="$mac" '
        $1 == "mojo_build" || $1 == "mojo_run_check" {
            seen[$1] = 1
            if ($2 != "Re" || $3 != M) print $1 " ran as " $2 " with " $3 ", not on " M
        }
        END {
            if (!("mojo_build" in seen)) print "mojo_build did not execute"
            if (!("mojo_run_check" in seen)) print "mojo_run_check did not execute"
        }')
    rows=$(report_outputs "$2") || { echo "cannot read $2"; return 1; }
    root=$(printf '%s\n' "$rows" | head -n 1)
    exe=$(printf '%s\n' "$rows" | tail -n +2 | grep '/hello$')
    stdout=$(printf '%s\n' "$rows" | tail -n +2 | grep '/hello\.stdout$')
    if [ "$(printf '%s\n' "$exe" | grep -c .)" != 1 ] || [ "$(printf '%s\n' "$stdout" | grep -c .)" != 1 ]; then
        bad="$bad
outputs: $(printf '%s\n' "$rows" | tail -n +2 | paste -sd ' ' -)"
    else
        cmp -s "$root/$stdout" <(printf 'hello from mojo\n') || bad="$bad
run check stdout differs"
        if ! listing=$(inspect_tool macho "$root/$exe" 2>&1); then
            bad="$bad
hello: $listing"
        else
            printf '%s\n' "$listing" | grep -qx "header${TAB}0x100000c${TAB}2" ||
                bad="$bad
hello: $(printf '%s\n' "$listing" | grep '^header' | tr '\t' ' ')"
            rpaths=$(printf '%s\n' "$listing" | awk -F '\t' '$1 == "rpath" { print $2 }' | paste -sd ' ' -)
            [ "$rpaths" = "@loader_path/lib" ] || bad="$bad
hello: run paths [$rpaths]"
            bad="$bad
$(printf '%s\n' "$listing" | awk -F '\t' '
                $1 == "load" && $2 !~ /^(\/usr\/lib\/|\/System\/Library\/)/ && $2 != "@rpath/libKGENCompilerRTShared.dylib" { print "hello loads " $2 }
                $1 == "minos" && $2 != "11.0.0" { print "hello: minos " $2 }')"
        fi
        if grep -aqF '/.bbworker/' "$root/$exe" || grep -aqF '.komira_action' "$root/$exe"; then
            bad="$bad
hello names a worker path"
        fi
    fi
    bad=$(printf '%s\n' "$bad" | grep .)
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad" | paste -sd ';' - | sed 's/;/; /g'
        return 1
    fi
    echo "mojo_build and mojo_run_check ran remotely with $MAC_PROPS; arm64, macOS 11.0, run path @loader_path/lib"
}

DARWIN=(--target-platforms komira//tools/build/platforms:darwin-arm64)
KEY=komira_re.darwin_arm64_properties
HOSTS_KEY=komira_re.darwin_macos_hosts
PLACEHOLDER=(-c "$KEY=pool=unreachable-check-only" -c "$HOSTS_KEY=0.0-check")
UNSET=(-c "$KEY=" -c "$HOSTS_KEY=")
MOJO_TARGETS=(//tools/build/examples:hello //tools/build/examples:hellopkg //tools/build/examples:test_hellopkg //tools/build/examples/libgate_ok:libgate_ok)

resolve() { # log name, args...: prints "<target> <execution platform>|FAILED"
    local name=$1
    shift
    "$BUCK2" audit execution-platform-resolution "$@" > "$LOG/$name.txt" 2>&1 || return 1
    awk '/^[a-z]+\/\/[^ ]* \(/ { t = $1 }
         t != "" && /^  Execution platform: / { print t, $3; t = "" }
         t != "" && /^  Failed to configure/ { print t, "FAILED"; t = "" }' "$LOG/$name.txt"
}

# ---- 1. unset: nothing registered --------------------------------------------
if ! got=$(resolve darwin_unset "${UNSET[@]}" "${DARWIN[@]}" //tools/build/examples:hello); then
    fail "unset: audit failed (see $LOG/darwin_unset.txt)"
elif [ "$got" != "komira//tools/build/examples:hello FAILED" ]; then
    fail "unset: a darwin-arm64 target configured with no macOS platform: $got"
elif ! grep -qF 'exec_compatible_with requires `prelude//os/constraints:macos`' "$LOG/darwin_unset.txt"; then
    fail "unset: the refusal does not name the macos constraint (see $LOG/darwin_unset.txt)"
elif [ "$(resolve darwin_unset_linux "${UNSET[@]}" //tools/build/examples:hello)" != "komira//tools/build/examples:hello komira//tools/build/platforms:linux-x86_64" ]; then
    fail "unset: the linux target no longer resolves to linux-x86_64 (see $LOG/darwin_unset_linux.txt)"
else
    pass "unset: no macOS platform; a darwin-arm64 target fails to configure, linux resolves as before"
fi

# ---- 2. set: resolution and load-time refusals --------------------------------
want=$(printf '%s komira//tools/build/platforms:darwin-arm64\n' "${MOJO_TARGETS[@]/#\/\//komira//}"
       printf '%s komira//tools/build/platforms:linux-x86_64\n' komira//tools/build/toolchains/darwin:mojo_compiler komira//tools/build/toolchains/darwin:mojo_runtime \
           komira//tools/build/toolchains/darwin:gate_runner komira//tools/build/toolchains/darwin:launcher komira//tools/build/toolchains/darwin:link)
want=$(printf '%s\n' "$want" | LC_ALL=C sort)
if ! got=$(resolve darwin_set "${PLACEHOLDER[@]}" "${DARWIN[@]}" "${MOJO_TARGETS[@]}" \
        komira//tools/build/toolchains/darwin:mojo_compiler komira//tools/build/toolchains/darwin:mojo_runtime komira//tools/build/toolchains/darwin:gate_runner \
        komira//tools/build/toolchains/darwin:launcher komira//tools/build/toolchains/darwin:link); then
    fail "set: audit failed (see $LOG/darwin_set.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "set: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^[<>]' | tr '\n' ' ')"
elif [ "$(resolve darwin_set_linux "${PLACEHOLDER[@]}" "${MOJO_TARGETS[@]}" | awk '{print $2}' | sort -u)" != "komira//tools/build/platforms:linux-x86_64" ]; then
    fail "set: a linux target left linux-x86_64 once a macOS platform was registered (see $LOG/darwin_set_linux.txt)"
else
    pass "set: ${#MOJO_TARGETS[@]} darwin-arm64 Mojo targets on darwin-arm64, darwin unpacking on linux-x86_64, linux unchanged"
fi
if "$BUCK2" audit execution-platform-resolution -c "$KEY=pool=mac-only-no-hosts" -c "$HOSTS_KEY=" "${DARWIN[@]}" //tools/build/examples:hello \
        > "$LOG/darwin_no_hosts.txt" 2>&1; then
    fail "load: a macOS property set without darwin_macos_hosts was accepted"
elif ! grep -qF 'names no macOS host' "$LOG/darwin_no_hosts.txt"; then
    fail "load: the missing-hosts refusal failed for another reason (see $LOG/darwin_no_hosts.txt)"
elif MC=$(cfg_value komira_re.linux_x86_64_properties) && [ -n "$MC" ] &&
    "$BUCK2" audit execution-platform-resolution -c "$HOSTS_KEY=0.0-check" \
        -c "$KEY=$MC" //tools/build/examples:hello > "$LOG/darwin_linux_set.txt" 2>&1; then
    fail "load: a macOS property set equal to the linux set was accepted"
elif ! grep -qF 'must name macOS workers' "$LOG/darwin_linux_set.txt"; then
    fail "load: the linux-set refusal failed for another reason (see $LOG/darwin_linux_set.txt)"
else
    pass "load: a macOS property set without darwin_macos_hosts, or equal to a linux set, is refused"
fi
if ! "$BUCK2" targets tests//functional/darwin: > "$LOG/darwin_cases.txt" 2>&1; then
    fail "load: a darwin_properties_refusal case failed (see $LOG/darwin_cases.txt)"
elif ! grep -qx 'tests//functional/darwin:shell_lint' "$LOG/darwin_cases.txt"; then
    fail "load: tests//functional/darwin was not loaded (see $LOG/darwin_cases.txt)"
else
    pass "load: an empty property set and malformed host identities are refused (cases.bzl)"
fi
if ! "$BUCK2" build "${UNSET[@]}" 'komira//tools/build/toolchains/darwin/...' > "$LOG/darwin_wildcard.txt" 2>&1; then
    fail "unset: a wildcard over tools/build/toolchains/darwin fails without a macOS platform (see $LOG/darwin_wildcard.txt)"
elif ! grep -q 'komira//tools/build/toolchains/darwin:link ' "$LOG/darwin_wildcard.txt" ||
    ! grep -q 'komira//tools/build/toolchains/darwin:mojo ' "$LOG/darwin_wildcard.txt"; then
    fail "unset: the wildcard did not report the darwin-only targets as skipped (see $LOG/darwin_wildcard.txt)"
else
    pass "unset: a wildcard over tools/build/toolchains/darwin skips the darwin-only targets"
fi

# ---- 3. darwin compile command lines ------------------------------------------
abs_path_re="[\"' =:]/[A-Za-z][A-Za-z0-9_.-]*"
if ! "$BUCK2" aquery "${PLACEHOLDER[@]}" "${DARWIN[@]}" 'deps(set(//tools/build/examples:hello_pkg_user //tools/build/examples:test_hellopkg))' \
        --output-attribute cmd --output-attribute env --output-attribute category --json \
        > "$LOG/darwin_aquery.json" 2> "$LOG/darwin_aquery.err"; then
    fail "commands: aquery failed (see $LOG/darwin_aquery.err)"
elif ! verdict=$(compile_verdict "$LOG/darwin_aquery.json"); then
    fail "commands: ${verdict:-no verdict} (see $LOG/darwin_aquery.json)"
elif grep -oE "$abs_path_re" "$LOG/darwin_aquery.json" > "$LOG/darwin_abs_paths.txt"; then
    fail "commands: absolute paths in darwin action commands: $(sort -u "$LOG/darwin_abs_paths.txt" | tr '\n' ' ')"
else
    pass "commands: $verdict use the macOS wrapper, the osx-arm64 closure and apple-m1; no zig, no absolute path"
fi

# ---- 4. linux actions unchanged by the darwin key -----------------------------
linux_q="deps(set($(printf '"%s" ' //tools/build/examples:hello //tools/build/examples:hello_pkg_user "${MOJO_TARGETS[@]}")))"
if ! "$BUCK2" aquery "${UNSET[@]}" "$linux_q" --output-attribute cmd --output-attribute env --json > "$LOG/linux_unset.json" 2> "$LOG/linux_unset.err" ||
    ! "$BUCK2" aquery "${PLACEHOLDER[@]}" "$linux_q" --output-attribute cmd --output-attribute env --json > "$LOG/linux_set.json" 2> "$LOG/linux_set.err"; then
    fail "linux: aquery failed (see $LOG/linux_unset.err, $LOG/linux_set.err)"
elif ! grep -q '"cmd"' "$LOG/linux_unset.json"; then
    fail "linux: aquery returned no commands"
elif ! cmp -s "$LOG/linux_unset.json" "$LOG/linux_set.json"; then
    fail "linux: action commands change when a macOS platform is registered (diff $LOG/linux_unset.json $LOG/linux_set.json)"
else
    pass "linux: $(grep -c '"cmd"' "$LOG/linux_unset.json") linux actions identical with and without a macOS platform"
fi

# ---- 5. the osx-arm64 closure, built on the farm --------------------------------
if ! "$BUCK2" build "${DARWIN[@]}" komira//tools/build/toolchains/darwin:mojo_compiler komira//tools/build/toolchains/darwin:mojo_runtime komira//tools/build/toolchains/darwin:gate_runner \
        komira//tools/build/toolchains/darwin:launcher --materializations all --show-full-output \
        > "$LOG/darwin_closure.txt" 2> "$LOG/darwin_closure.log"; then
    fail "closure: build failed (see $LOG/darwin_closure.log)"
else
    out() { grep "^komira//tools/build/toolchains/darwin:$1 " "$LOG/darwin_closure.txt" | awk '{print $2}'; }
    if ! verdict=$(macho_closure "$(out mojo_compiler)" "$(out mojo_runtime)" 11.0 2>&1); then
        fail "closure: $(printf '%s' "$verdict" | tr '\n' ' ')"
    else
        pass "closure: $verdict"
    fi
    cfg="$(out mojo_compiler)/share/max/modular.cfg"
    if ! grep -qxF 'shared_libs = -Xlinker,-rpath,-Xlinker,@@MOJO_TOOLCHAIN_ROOT@@/lib;' "$cfg"; then
        fail "closure: modular.cfg's shared_libs is not what tools/build/mojo/darwin/mojo_wrapper.sh expects (see $cfg)"
    elif [ -e "$(out mojo_compiler)/bin/lld" ]; then
        fail "closure: bin/lld is in the closure, but links go through the cc on PATH"
    else
        pass "closure: modular.cfg asks for the one run path the wrapper rewrites; no bin/lld"
    fi
    bad=""
    for s in gate_runner:gate_runner.sh launcher:launch.sh; do
        if ! cmp -s "$(out "${s%%:*}")" <(cat tools/build/mojo/darwin/dyld_prelude.sh "tools/build/mojo/${s#*:}"); then bad="$bad ${s%%:*}"; fi
    done
    if [ -n "$bad" ]; then
        fail "dyld scripts:$bad differ from dyld_prelude.sh + the shared script"
    else
        pass "dyld scripts: gate_runner and launcher are the shared scripts behind dyld_prelude.sh"
    fi
fi

# ---- 6. the macOS scripts against stand-ins ------------------------------------
U="$LOG/darwin_unit"
mkdir -p "$U/bin"
BB="$PWD/tools/build/mojo/darwin/busybox.sh"
if ! sh "$BB" --install -s "$U/bin" || ! "$U/bin/mkdir" -p "$U/made" || [ ! -d "$U/made" ] ||
    [ "$(sh "$BB" sh -c 'echo ok')" != ok ]; then
    fail "busybox.sh: an applet does not run"
elif sh "$BB" curl --version > "$U/refuse.txt" 2>&1 || [ $? != 127 ] || ! grep -q "REFUSING" "$U/refuse.txt"; then
    fail "busybox.sh: an applet outside the list was not refused with 127"
elif [ "$(readlink "$U/bin/sh")" != "$BB" ] || [ -e "$U/bin/curl" ]; then
    fail "busybox.sh: --install -s linked something other than the applets to itself"
else
    pass "busybox.sh: applets run from /bin and /usr/bin, anything else refused (127)"
fi
sed 's|^exec /usr/bin/cc |printf "[%s]" |' tools/build/mojo/darwin/cc > "$U/cc"
got=$(sh "$U/cc" -o out -Xlinker -rpath -Xlinker /sandbox/lib x.o -Xlinker -L/l -Wl,-rpath,/q -rpath /z -lm)
printf 'libc.a\n-lc++\n' > "$U/tail"
got2=$(KOMIRA_CC_RUNPATH=@loader_path/../.. KOMIRA_CC_LINK_TAIL="$U/tail" sh "$U/cc" -o out x.o)
if ! grep -q '^exec /usr/bin/cc ' tools/build/mojo/darwin/cc; then
    fail "cc shim: it no longer ends in exec /usr/bin/cc (update this check)"
elif [ "$got" != "[-Wl,-S][-Wl,-rpath,@loader_path/lib][-o][out][x.o][-Xlinker][-L/l][-lm]" ]; then
    fail "cc shim: rewrote the command line to $got"
elif [ "$got2" != "[-Wl,-S][-Wl,-rpath,@loader_path/../..][-o][out][x.o][libc.a][-lc++]" ]; then
    fail "cc shim: with a run path and a link tail, rewrote the command line to $got2"
else
    pass "cc shim: every run path replaced by the wrapper's (@loader_path/lib by default); the link tail goes last"
fi
# host_identity.sh against stand-ins for the host tools it runs: every tool is
# named by absolute path, so a copy with those paths rewritten runs here.
H="$U/host"
mkdir -p "$H"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$H/$1"; chmod +x "$H/$1"; }
stub xcode-select 'echo /Library/Developer/CommandLineTools'
stub xcrun 'case "$1" in --show-sdk-version) echo 26.5 ;; --show-sdk-build-version) echo 25F71 ;; *) exit 1 ;; esac'
stub cc 'echo "Apple clang version 17.0.0 (clang-1700.3.19.1)"; echo "Target: arm64-apple-darwin25.5.0"'
stub ld 'echo "@(#)PROGRAM:ld PROJECT:ld-1167.5" >&2; echo "BUILD 08:00:00 Jan  1 2026" >&2'
stub sw_vers '[ "$1" = -buildVersion ] && echo 25F80'
stub md5 '[ "$1" = -q ] && /usr/bin/md5sum | /usr/bin/cut -c1-32'
stub sed 'exec /usr/bin/sed "$@"'
sed -e "s|/usr/bin/xcode-select|$H/xcode-select|; s|/usr/bin/xcrun|$H/xcrun|g; s|/usr/bin/cc|$H/cc|" \
    -e "s|/usr/bin/ld|$H/ld|; s|/usr/bin/sw_vers|$H/sw_vers|; s|/sbin/md5|$H/md5|; s|/usr/bin/sed|$H/sed|" \
    tools/build/mojo/darwin/host_identity.sh > "$U/host_identity.sh"
hid() { (PATH="$U/bin" sh "$U/host_identity.sh" "$@"); }
fields_want=$(printf '%s\n' developer_dir=/Library/Developer/CommandLineTools sdk_version=26.5 sdk_build=25F71 \
    'cc=Apple clang version 17.0.0 (clang-1700.3.19.1)' 'ld=@(#)PROGRAM:ld PROJECT:ld-1167.5' os_build=25F80)
host_want="26.5-$(printf '%s\n' "$fields_want" | md5sum | cut -c1-16)"
if grep -E '/(usr/)?s?bin/' "$U/host_identity.sh" | grep -v "$H/" | grep -vq '^#'; then
    fail "host_identity.sh: it runs a host tool this check does not stand in for: $(grep -nE '/(usr/)?s?bin/' "$U/host_identity.sh" | grep -v "$H/" | grep -v ':#' | tr '\n' ' ')"
elif [ "$(hid --fields)" != "$fields_want" ]; then
    fail "host_identity.sh: --fields printed $(hid --fields | tr '\n' '|')"
elif [ "$(hid)" != "$host_want" ]; then
    fail "host_identity.sh: printed '$(hid)', expected '$host_want'"
else
    bad=""
    for f in xcode-select xcrun cc ld sw_vers; do
        cp "$H/$f" "$H/$f.good"
        stub "$f" 'echo other-build-99 ; echo other-build-99 >&2'
        [ "$(hid 2> /dev/null)" != "$host_want" ] || bad="$bad $f"
        mv "$H/$f.good" "$H/$f"
    done
    cp "$H/sw_vers" "$H/sw_vers.good"
    stub sw_vers 'exit 1'
    hid > /dev/null 2> "$U/hid_err.txt"
    rc=$?
    mv "$H/sw_vers.good" "$H/sw_vers"
    if [ -n "$bad" ]; then
        fail "host_identity.sh: the value does not change with the output of:$bad"
    elif [ "$rc" != 2 ] || ! grep -q "cannot read 'os_build'" "$U/hid_err.txt"; then
        fail "host_identity.sh: an unreadable field was not refused (rc=$rc)"
    else
        pass "host_identity.sh: the value covers developer dir, SDK version and build, cc, ld and OS build; an unreadable field is refused"
    fi
fi

TC="$U/tc"
mkdir -p "$TC/bin" "$TC/lib" "$TC/share/max" "$U/link" "$U/run"
printf '#!/bin/sh\nexit 0\n' > "$TC/bin/mojo"
chmod +x "$TC/bin/mojo"
printf 'x' > "$TC/lib/libKGENCompilerRTShared.dylib"
printf 'bin/mojo\nlib/libKGENCompilerRTShared.dylib\nshare/max/modular.cfg\n' > "$TC/CLOSURE_MANIFEST"
cfg='[mojo-max]\ndriver_path = @@MOJO_TOOLCHAIN_ROOT@@/bin/mojo\nshared_libs = -Xlinker,-rpath,-Xlinker,@@MOJO_TOOLCHAIN_ROOT@@/lib;\n'
printf "$cfg" > "$TC/share/max/modular.cfg"
cp tools/build/mojo/darwin/cc "$U/link/cc"
cp "$U/host_identity.sh" "$U/link/host_identity.sh"
printf '0.0-check\n' > "$U/link/macos_hosts"
wrap() { (cd "$U/run" && rm -rf .komira_action && sh "$OLDPWD/tools/build/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 "$@" -- build x.mojo -o out > "$U/wrap.txt" 2>&1); }
wrap
rc=$?
rendered="$U/run/.komira_action/modular/modular.cfg"
if [ "$rc" != 2 ] || ! grep -q "this host's identity is '$host_want', not one of \\[0.0-check \\]" "$U/wrap.txt" ||
    ! grep -qxF 'sdk_build=25F71' "$U/wrap.txt"; then
    fail "wrapper: an unlisted host was not refused with its fields (rc=$rc, see $U/wrap.txt)"
elif ! grep -qxF 'shared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;' "$rendered" ||
    grep -qF '@@MOJO' "$rendered" || ! grep -qxF "driver_path = $TC/bin/mojo" "$rendered"; then
    fail "wrapper: modular.cfg rendered wrongly (see $rendered)"
else
    # Same SDK version, another toolchain: refused, not matched on the version.
    printf '26.5-ffffffffffffffff\n' > "$U/link/macos_hosts"
    wrap
    rc_same_sdk=$?
    printf '26.5-ffffffffffffffff\n%s\n' "$host_want" > "$U/link/macos_hosts"
    wrap --runpath='$ORIGIN/x' --shared-lib-probe 2> /dev/null
    rc_bad_opt=$?
    wrap --runpath=/abs
    rc_abs=$?
    grep -q 'is not \$ORIGIN-relative' "$U/wrap.txt" || rc_abs=x
    (cd "$U/run" && rm -rf .komira_action && sh "$OLDPWD/tools/build/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 -- \
        build --emit shared-lib x.mojo -o out > "$U/wrap.txt" 2>&1)
    rc_shared=$?
    grep -q 'bundles are linux only' "$U/wrap.txt" || rc_shared=x
    # A C-ABI library names itself for dyld (mojo_shared_lib) and is let through to
    # the compile; the bundle's `-soname` spelling is still refused.
    (cd "$U/run" && rm -rf .komira_action && sh "$OLDPWD/tools/build/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 -- \
        build --emit shared-lib -Xlinker -soname -Xlinker x.so x.mojo -o out > "$U/wrap.txt" 2>&1)
    rc_soname=$?
    grep -q 'bundles are linux only' "$U/wrap.txt" || rc_soname=x
    (cd "$U/run" && rm -rf .komira_action && sh "$OLDPWD/tools/build/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 -- \
        build --emit shared-lib -Xlinker -install_name -Xlinker @rpath/x.dylib x.mojo -o out > "$U/wrap.txt" 2>&1)
    rc_dylib=$?
    grep -q "compiler exited 0 but out is missing" "$U/wrap.txt" || rc_dylib=x
    wrap --runpath='$ORIGIN/../..' --source-root=src
    rc=$?
    # The stand-in compiler writes nothing, so a host that passes the identity
    # check reaches the output check (exit 3).
    if [ "$rc_same_sdk" != 2 ]; then
        fail "wrapper: a host with a listed SDK version but another toolchain digest was accepted (rc=$rc_same_sdk)"
    elif [ "$rc_bad_opt" != 2 ] || [ "$rc_abs" != 2 ] || [ "$rc_shared" != 2 ] || [ "$rc_soname" != 2 ]; then
        fail "wrapper: an unknown option, an absolute run path or a bundle shared-lib build was not refused ($rc_bad_opt $rc_abs $rc_shared $rc_soname)"
    elif [ "$rc_dylib" != 3 ]; then
        fail "wrapper: a self-named (install_name) shared-lib build was refused, or did not reach the compile (rc=$rc_dylib, see $U/wrap.txt)"
    elif [ "$rc" != 3 ] || ! grep -q "compiler exited 0 but out is missing" "$U/wrap.txt"; then
        fail "wrapper: a listed host was not accepted (rc=$rc, see $U/wrap.txt)"
    else
        printf "$cfg" | sed 's|@@MOJO_TOOLCHAIN_ROOT@@/lib;|/opt/lib;|' > "$TC/share/max/modular.cfg"
        wrap
        rc=$?
        if [ "$rc" != 2 ] || ! grep -q "shared_libs is not the one run path" "$U/wrap.txt"; then
            fail "wrapper: an unexpected shared_libs was not refused (rc=$rc, see $U/wrap.txt)"
        else
            printf "$cfg" > "$TC/share/max/modular.cfg"
            : > "$TC/lib/libKGENCompilerRTShared.dylib"
            wrap
            rc=$?
            if [ "$rc" != 2 ] || ! grep -q "REFUSING: toolchain member 'lib/libKGENCompilerRTShared.dylib'" "$U/wrap.txt"; then
                fail "wrapper: an incomplete closure was not refused (rc=$rc, see $U/wrap.txt)"
            else
                pass "wrapper: refuses an incomplete closure, an unexpected shared_libs, a shared-lib build, a non-\$ORIGIN run path and an unlisted host; accepts a listed one; renders @loader_path/lib"
            fi
        fi
    fi
fi

# The compile watchdog, on this client (ps(1) here is procps, on the workers
# macOS's; the wrapper reads only fields both print). The stand-in compiler
# reads its behaviour from run/mode: `hang` parks itself and a child for 30 s
# (a watchdog that does not fire fails the case, it does not hang it), `spin`
# uses CPU for 5 s in the shell itself (a loop of forks would put its CPU in
# children reaped between samples, which ps(1) does not count).
printf 'x' > "$TC/lib/libKGENCompilerRTShared.dylib"
printf "$cfg" > "$TC/share/max/modular.cfg"
printf '%s\n' "$host_want" > "$U/link/macos_hosts"
cat > "$TC/bin/mojo" <<'MOJO'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
case "$(cat mode)" in
    hang) echo $$ > compiler.pid; /bin/sleep 30 & echo $! > child.pid; wait ;;
    spin) end=$(($(/bin/date +%s) + 5)); while [ "$(/bin/date +%s)" -lt "$end" ]; do i=0; while [ $i -lt 20000 ]; do i=$((i + 1)); done; done ;;
esac
echo compiled > "$out"
MOJO
chmod +x "$TC/bin/mojo"
alive() { # pid: a live process, not a zombie
    case "$(sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/$1/stat" 2> /dev/null)" in "" | Z | X) return 1 ;; *) return 0 ;; esac
}
survivors() { # the stand-in compiler and its child, if still alive
    for p in $(cat "$U/run/compiler.pid" "$U/run/child.pid" 2> /dev/null); do alive "$p" && printf ' %s' "$p"; done
}
reap() { for p in $(cat "$U/run/compiler.pid" "$U/run/child.pid" 2> /dev/null); do kill -9 "$p" 2> /dev/null; done; rm -f "$U/run/compiler.pid" "$U/run/child.pid"; }
KNOBS="--watchdog-idle-secs=3 --watchdog-sample-secs=1"
echo hang > "$U/run/mode"
# shellcheck disable=SC2086 # KNOBS is two flags
wrap $KNOBS
wd_hang=$?
cp "$U/wrap.txt" "$U/wrap_hang.txt"
sleep 1
wd_hang_left=$(survivors)
grep -q 'mojo-watchdog: killed deadlocked compiler' "$U/wrap.txt" || wd_hang="$wd_hang(no message)"
reap
echo spin > "$U/run/mode"
# shellcheck disable=SC2086 # KNOBS is two flags
wrap $KNOBS
wd_spin=$?
cp "$U/wrap.txt" "$U/wrap_spin.txt"
echo hang > "$U/run/mode"
(cd "$U/run" && rm -rf .komira_action && exec sh "$OLDPWD/tools/build/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 \
    --watchdog-idle-secs=600 --watchdog-sample-secs=1 -- build x.mojo -o out > "$U/wrap_killed.txt" 2>&1) &
w=$!
n=0
while [ ! -s "$U/run/child.pid" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
kill -s KILL "$w"
wait "$w" 2> /dev/null
n=0
while [ -n "$(survivors)" ] && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
wd_kill_left=$(survivors)
[ -s "$U/run/child.pid" ] || wd_kill_left=" (the stand-in did not start)"
reap
wrap --watchdog-idle-secs=5m
wd_bad=$?
if [ "$wd_hang" != 124 ] || [ -n "$wd_hang_left" ]; then
    fail "wrapper watchdog: a hung compile was not killed with 124 and the message (rc=$wd_hang, alive:${wd_hang_left:- none}; see $U/wrap_hang.txt)"
elif [ "$wd_spin" != 0 ]; then
    fail "wrapper watchdog: a compile using CPU for 5 s did not finish (rc=$wd_spin, see $U/wrap_spin.txt)"
elif [ -n "$wd_kill_left" ]; then
    fail "wrapper watchdog: SIGKILL to the wrapper left its compiler running:$wd_kill_left (see $U/wrap_killed.txt)"
elif [ "$wd_bad" != 2 ]; then
    fail "wrapper watchdog: a malformed knob was not refused (rc=$wd_bad)"
else
    pass "wrapper watchdog: a hung compile is killed (124), one using CPU is not, a killed wrapper takes its compiler with it, a malformed knob is refused"
fi

# run_check.sh starts the binary with no library path of any loader.
printf '#!/bin/sh\necho "[${LD_LIBRARY_PATH-}${LD_PRELOAD-}${DYLD_LIBRARY_PATH-}${DYLD_FALLBACK_LIBRARY_PATH-}${DYLD_INSERT_LIBRARIES-}]"\n' > "$U/envbin"
chmod +x "$U/envbin"
if ! (cd "$U" && LD_LIBRARY_PATH=/a LD_PRELOAD=/b DYLD_LIBRARY_PATH=/c DYLD_FALLBACK_LIBRARY_PATH=/d DYLD_INSERT_LIBRARIES=/e \
        sh "$OLDPWD/tools/build/mojo/run_check.sh" "$BB" envbin env_out.txt) > "$U/run_check.txt" 2>&1; then
    fail "run_check.sh: the stand-in binary did not run (see $U/run_check.txt)"
elif [ "$(cat "$U/env_out.txt")" != "[]" ]; then
    fail "run_check.sh: the binary inherited a library path: $(cat "$U/env_out.txt")"
else
    pass "run_check.sh: the binary starts with no LD_* or DYLD_* library path"
fi

# gate_runner.sh hands the test the toolchain's lib/ through DYLD_LIBRARY_PATH.
# On macOS /usr/bin/env is a system-integrity-protected binary: dyld prunes every
# DYLD_* variable from the environment of such a process, so a test started
# through the `env` applet never sees the variable and dies with "Library not
# loaded: @rpath/libKGENCompilerRTShared.dylib". The stand-in busybox below
# prunes them in its `env` applet as the operating system does; the test must
# still see the variable, and its --env variables.
mkdir -p "$U/gate/root/bin" "$U/gate/tmp"
cat > "$U/sip_busybox.sh" <<SIPBB
#!/bin/sh
if [ "\$1" = env ]; then
    shift
    unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES
    exec /usr/bin/env "\$@"
fi
exec sh "$BB" "\$@"
SIPBB
chmod +x "$U/sip_busybox.sh"
cat > "$U/gate/root/bin/seen" <<SEEN
#!/bin/sh
printf '%s|%s\n' "\${DYLD_LIBRARY_PATH-}" "\${GATE_FOO-}" > "$U/gate/seen.txt"
SEEN
chmod +x "$U/gate/root/bin/seen"
# A --env BIN naming another program must not replace the test.
printf '#!/bin/sh\n: > "%s/gate/other_ran"\n' "$U" > "$U/gate/root/bin/other"
chmod +x "$U/gate/root/bin/other"
cat tools/build/mojo/darwin/dyld_prelude.sh tools/build/mojo/gate_runner.sh > "$U/gate/gate_runner.sh"
rm -f "$U/gate/seen.txt" "$U/gate/marker" "$U/gate/other_ran"
if ! (cd "$U/gate/tmp" && sh "$U/gate/gate_runner.sh" "$U/sip_busybox.sh" "$TC" //stand:in "$U/gate/root/bin/seen" "$U/gate/marker" --env GATE_FOO=bar --env "BIN=$U/gate/root/bin/other") > "$U/gate/run.txt" 2>&1; then
    fail "gate_runner.sh: the stand-in test failed (see $U/gate/run.txt)"
elif [ "$(cat "$U/gate/seen.txt")" != "$TC/lib|bar" ]; then
    fail "gate_runner.sh: the test saw [$(cat "$U/gate/seen.txt")], not [$TC/lib|bar]: DYLD_LIBRARY_PATH did not reach it (an SIP binary between the runner and the test prunes it)"
elif [ -e "$U/gate/other_ran" ]; then
    fail "gate_runner.sh: --env BIN=<other program> ran that program in place of the test"
else
    pass "gate_runner.sh: the test starts with DYLD_LIBRARY_PATH at the toolchain's lib/ although env prunes DYLD_*, and with its --env variables, and --env BIN does not replace it"
fi

# ---- 7. live, on the macOS workers ----------------------------------------------
MAC_PROPS=$(cfg_value "$KEY")
MAC_HOSTS=$(cfg_value "$HOSTS_KEY")
if [ -z "$MAC_PROPS" ] || [ -z "$MAC_HOSTS" ]; then
    echo "SKIP  darwin: live (no $KEY / $HOSTS_KEY in this checkout's config)"
else
    ISO=komira_tests_darwin
    # A clean isolated daemon and --no-remote-cache, so every action runs and
    # `what-ran` records where (a cache hit records no properties).
    if ! "$BUCK2" --isolation-dir "$ISO" clean > "$LOG/darwin_live_clean.log" 2>&1; then
        fail "live: cannot clean the isolated buck-out (see $LOG/darwin_live_clean.log)"
    elif ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" tests//functional/darwin:host_census \
            --build-report "$LOG/darwin_census.json" > "$LOG/darwin_census.log" 2>&1; then
        fail "live: host census failed (see $LOG/darwin_census.log)"
    elif ! verdict=$(census_verdict "$LOG/darwin_census.json" "$MAC_HOSTS"); then
        fail "live: $verdict"
    else
        pass "live: host census: $verdict"
    fi
    if ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" //tools/build/examples:hello \
            '//tools/build/examples:hello[run_check]' --build-report "$LOG/darwin_hello.json" > "$LOG/darwin_hello.log" 2>&1; then
        fail "live: //tools/build/examples:hello or its run check failed on macOS (see $LOG/darwin_hello.log)"
    elif ! "$BUCK2" --isolation-dir "$ISO" log what-ran --format json > "$LOG/darwin_hello.what_ran.json" 2>&1; then
        fail "live: cannot read what-ran"
    elif ! verdict=$(hello_verdict "$LOG/darwin_hello.what_ran.json" "$LOG/darwin_hello.json"); then
        fail "live: $verdict (see $LOG/darwin_hello.what_ran.json)"
    else
        pass "live: $verdict"
    fi
    # mojo_shared_lib: a .dylib, its gate run on a macOS worker; the same red twins as Linux.
    if ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" --show-full-output \
            //tools/build/examples/shared_lib:plain //tools/build/examples/shared_lib:plain_exact > "$LOG/darwin_sharedlib.log" 2>&1; then
        fail "live: mojo_shared_lib examples failed on macOS (see $LOG/darwin_sharedlib.log)"
    else
        dylib=$(grep -E ' [^ ]*/pub/plain\.dylib$' "$LOG/darwin_sharedlib.log" | sed 's/^[^ ]* //')
        # Mach-O arm64 (the magic, cf fa ed fe), named `@rpath/plain.dylib`, with no build path in it.
        if [ -z "$dylib" ] || [ "$(head -c4 "$dylib" | od -An -tx1 | tr -d ' \n')" != cffaedfe ] ||
            ! grep -qF '@rpath/plain.dylib' "$dylib" || grep -qF 'buck-out' "$dylib"; then
            fail "live: plain.dylib is not a Mach-O library named @rpath/plain.dylib free of build paths (see $LOG/darwin_sharedlib.log)"
        else
            pass "live: mojo_shared_lib builds a .dylib on macOS and its gate passes (plain, plain_exact)"
        fi
    fi
    # A mojo_library's welded test: the test binary loads the runtime library
    # through DYLD_LIBRARY_PATH, which gate_runner.sh must hand it past
    # macOS's pruning (section 6 and tests//functional/test_data:runner_cases
    # show the same against stand-ins).
    if ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" \
            //tools/build/examples/libgate_ok:libgate_ok > "$LOG/darwin_welded.log" 2>&1; then
        fail "live: the welded test of //tools/build/examples/libgate_ok failed on macOS (see $LOG/darwin_welded.log)"
    else
        pass "live: a mojo_library's welded test passes on macOS (libgate_ok)"
    fi
    for t in missing_export:'MISSING EXPORT: neg_missing' failing_driver:'GATED TEST FAILED' plain_leaks:'plain_hidden leaked into the dynamic symbol table'; do
        if timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" "tests//negative/shared_lib:${t%%:*}" > "$LOG/darwin_neg_${t%%:*}.log" 2>&1; then
            fail "live: tests//negative/shared_lib:${t%%:*} built on macOS, but it must fail"
        elif ! grep -qF -- "${t#*:}" "$LOG/darwin_neg_${t%%:*}.log"; then
            fail "live: tests//negative/shared_lib:${t%%:*} failed without '${t#*:}' (see $LOG/darwin_neg_${t%%:*}.log)"
        else
            pass "live: tests//negative/shared_lib:${t%%:*} is red on macOS for its own reason"
        fi
    done
    if timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache "${DARWIN[@]}" -c "$HOSTS_KEY=0.0-nohost" \
            //tools/build/examples:hello > "$LOG/darwin_refuse.log" 2>&1; then
        fail "live: a compile whose host list names no worker succeeded"
    elif ! grep -q "REFUSING: this host's identity is '[^']*', not one of \[0.0-nohost \]" "$LOG/darwin_refuse.log" ||
        ! grep -q "exit code 2" "$LOG/darwin_refuse.log"; then
        fail "live: the unlisted-host compile failed for another reason (see $LOG/darwin_refuse.log)"
    else
        pass "live: a compile on a host not in darwin_macos_hosts is refused on the worker (exit 2), naming its fields"
    fi
    "$BUCK2" --isolation-dir "$ISO" kill > /dev/null 2>&1
fi

[ "$fails" = 0 ]
