#!/usr/bin/env bash
# checks/darwin/check.sh -- the macOS arm64 target and execution platform.
#
# usage: checks/darwin/check.sh <log_dir>   (from the repo root; BUCK2 names
#        the buck2 binary). Prints PASS/FAIL lines; exits 1 if any failed.
#
# No macOS worker is needed. What runs where:
#   1. Unset `[komira_re] darwin_mojo_compile_properties`: no macOS platform
#      is registered, and a darwin-arm64 Mojo target fails to configure
#      (naming the macos constraint) while the linux target still resolves to
#      exec-mojo.
#   2. Set (a placeholder, resolution only, nothing is built): darwin-arm64
#      Mojo targets resolve to exec-mojo-darwin-arm64, the darwin toolchain's
#      unpacking to linux exec-light, linux targets are unchanged; a property
#      set without `macos_host`, or equal to a linux set, is refused at load,
#      and so (checks//darwin:BUCK, cases.bzl) is one whose `macos_host`
#      differs from the value the toolchain promises. Unset, a wildcard over
#      toolchains//darwin skips the darwin-only targets instead of failing.
#   3. The darwin compile command lines (aquery): the macOS wrapper and
#      busybox, the osx-arm64 compiler closure, --target-cpu apple-m1, the
#      deployment target, no zig, no absolute path.
#   4. The linux actions are the same with and without the darwin key.
#   5. The osx-arm64 closure, unpacked and cut on the farm (linux `light`
#      workers): checks/darwin/macho.py over its Mach-O load commands, and the
#      DYLD scripts are the shared scripts behind dyld_prelude.sh.
#   6. The macOS scripts, run on this machine against stand-ins: busybox.sh
#      (applets only from /bin and /usr/bin, anything else refused), the cc
#      shim (run paths replaced by @loader_path/lib), host_identity.sh (every
#      field in the digest; an unreadable field refused), the wrapper
#      (incomplete closure, unexpected shared_libs and a host whose identity
#      is not the promised one are refused, the promised host is accepted;
#      modular.cfg is rendered with the one run path @loader_path/lib), and
#      run_check.sh (clears DYLD_* as well as LD_*).
#
# Not covered, because only a macOS worker can answer: which linker a macOS
# link really runs (the cc on PATH is what is wired; bin/lld is kept as a
# hedge), and whether the compiler execs a tool by name that PATH lacks.

set -u
mkdir -p "$1" && LOG=$(cd "$1" && pwd) || { echo "usage: $0 <log_dir>" >&2; exit 2; }
BUCK2=${BUCK2:-buck2}
fails=0
pass() { echo "PASS  darwin: $1"; }
fail() { echo "FAIL  darwin: $1"; fails=$((fails + 1)); }

DARWIN=(--target-platforms komira//tools/build/platforms:darwin-arm64)
KEY=komira_re.darwin_mojo_compile_properties
PLACEHOLDER=(-c "$KEY=pool=unreachable-check-only,macos_host=0.0-check")
UNSET=(-c "$KEY=")
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
elif [ "$(resolve darwin_unset_linux "${UNSET[@]}" //tools/build/examples:hello)" != "komira//tools/build/examples:hello komira//tools/build/platforms:exec-mojo" ]; then
    fail "unset: the linux target no longer resolves to exec-mojo (see $LOG/darwin_unset_linux.txt)"
else
    pass "unset: no macOS platform; a darwin-arm64 target fails to configure, linux resolves as before"
fi

# ---- 2. set: resolution and load-time refusals --------------------------------
want=$(printf '%s komira//tools/build/platforms:exec-mojo-darwin-arm64\n' "${MOJO_TARGETS[@]/#\/\//komira//}"
       printf '%s komira//tools/build/platforms:exec-light\n' komira//tools/build/toolchains/darwin:mojo_compiler komira//tools/build/toolchains/darwin:mojo_runtime \
           komira//tools/build/toolchains/darwin:gate_runner komira//tools/build/toolchains/darwin:launcher komira//tools/build/toolchains/darwin:link)
want=$(printf '%s\n' "$want" | LC_ALL=C sort)
if ! got=$(resolve darwin_set "${PLACEHOLDER[@]}" "${DARWIN[@]}" "${MOJO_TARGETS[@]}" \
        komira//tools/build/toolchains/darwin:mojo_compiler komira//tools/build/toolchains/darwin:mojo_runtime komira//tools/build/toolchains/darwin:gate_runner \
        komira//tools/build/toolchains/darwin:launcher komira//tools/build/toolchains/darwin:link); then
    fail "set: audit failed (see $LOG/darwin_set.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "set: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^[<>]' | tr '\n' ' ')"
elif [ "$(resolve darwin_set_linux "${PLACEHOLDER[@]}" "${MOJO_TARGETS[@]}" | awk '{print $2}' | sort -u)" != "komira//tools/build/platforms:exec-mojo" ]; then
    fail "set: a linux target left exec-mojo once a macOS platform was registered (see $LOG/darwin_set_linux.txt)"
else
    pass "set: ${#MOJO_TARGETS[@]} darwin-arm64 Mojo targets on exec-mojo-darwin-arm64, darwin unpacking on linux exec-light, linux unchanged"
fi
if "$BUCK2" audit execution-platform-resolution -c "$KEY=pool=mac-only-no-sdk" "${DARWIN[@]}" //tools/build/examples:hello \
        > "$LOG/darwin_no_sdk.txt" 2>&1; then
    fail "load: a macOS property set without macos_host was accepted"
elif ! grep -qF 'must carry `macos_host=<value>`' "$LOG/darwin_no_sdk.txt"; then
    fail "load: the missing-macos_host refusal failed for another reason (see $LOG/darwin_no_sdk.txt)"
elif MC=$("$BUCK2" audit config komira_re.mojo_compile_properties --style json 2> /dev/null |
        python3 -c 'import json, sys; print(list(json.load(sys.stdin).values())[0])' 2> /dev/null) && [ -n "$MC" ] &&
    "$BUCK2" audit execution-platform-resolution -c "komira_re.mojo_compile_properties=$MC,macos_host=1" \
        -c "$KEY=$MC,macos_host=1" //tools/build/examples:hello > "$LOG/darwin_linux_set.txt" 2>&1; then
    fail "load: a macOS property set equal to the linux mojo_compile set was accepted"
elif ! grep -qF 'must name macOS workers' "$LOG/darwin_linux_set.txt"; then
    fail "load: the linux-set refusal failed for another reason (see $LOG/darwin_linux_set.txt)"
else
    pass "load: a macOS property set without macos_host, or equal to a linux set, is refused"
fi
if ! "$BUCK2" targets checks//darwin: > "$LOG/darwin_cases.txt" 2>&1; then
    fail "load: a darwin_properties_refusal case failed (see $LOG/darwin_cases.txt)"
elif ! grep -qx 'checks//darwin:macho.py' "$LOG/darwin_cases.txt"; then
    fail "load: checks//darwin was not loaded (see $LOG/darwin_cases.txt)"
else
    pass "load: a property set whose macos_host differs from the toolchain's is refused (cases.bzl)"
fi
if ! "$BUCK2" build "${UNSET[@]}" 'toolchains//darwin/...' > "$LOG/darwin_wildcard.txt" 2>&1; then
    fail "unset: a wildcard over toolchains//darwin fails without a macOS platform (see $LOG/darwin_wildcard.txt)"
elif ! grep -q 'komira//tools/build/toolchains/darwin:link ' "$LOG/darwin_wildcard.txt" ||
    ! grep -q 'komira//tools/build/toolchains/darwin:mojo ' "$LOG/darwin_wildcard.txt"; then
    fail "unset: the wildcard did not report the darwin-only targets as skipped (see $LOG/darwin_wildcard.txt)"
else
    pass "unset: a wildcard over toolchains//darwin skips the darwin-only targets"
fi

# ---- 3. darwin compile command lines ------------------------------------------
abs_path_re="[\"' =:]/[A-Za-z][A-Za-z0-9_.-]*"
if ! "$BUCK2" aquery "${PLACEHOLDER[@]}" "${DARWIN[@]}" 'deps(set(//tools/build/examples:hello_pkg_user //tools/build/examples:test_hellopkg))' \
        --output-attribute cmd --output-attribute env --output-attribute category --json \
        > "$LOG/darwin_aquery.json" 2> "$LOG/darwin_aquery.err"; then
    fail "commands: aquery failed (see $LOG/darwin_aquery.err)"
elif ! verdict=$(python3 - "$LOG/darwin_aquery.json" << 'PY'
import json, sys
actions = json.load(open(sys.argv[1])).values()
compiles = [a for a in actions if a.get("category") in ("mojo_build", "mojo_build_test", "mojo_precompile")]
bad = []
if len([a for a in compiles if a["category"] == "mojo_build"]) < 1:
    bad.append("no mojo_build action")
for a in compiles:
    cmd = a["cmd"] if isinstance(a["cmd"], str) else " ".join(a["cmd"])
    for need in ("darwin/__busybox.sh__/busybox.sh", "darwin/__mojo_wrapper.sh__/mojo_wrapper.sh",
                 "toolchains/darwin/__mojo_compiler__/", "toolchains/darwin/__link__/", " 11.0, --,"):
        if need not in cmd:
            bad.append("%s lacks %r" % (a["category"], need))
    if "zig" in cmd:
        bad.append("%s names zig" % a["category"])
    if a["category"] != "mojo_precompile" and "--target-cpu, apple-m1" not in cmd:
        bad.append("%s does not target apple-m1" % a["category"])
print("; ".join(sorted(set(bad))) if bad else "%d compile actions" % len(compiles))
sys.exit(1 if bad else 0)
PY
); then
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
    if ! verdict=$(python3 checks/darwin/macho.py "$(out mojo_compiler)" "$(out mojo_runtime)" 11.0 2>&1); then
        fail "closure: $(printf '%s' "$verdict" | tr '\n' ' ')"
    else
        pass "closure: $verdict"
    fi
    cfg="$(out mojo_compiler)/share/max/modular.cfg"
    if ! grep -qxF 'shared_libs = -Xlinker,-rpath,-Xlinker,@@MOJO_TOOLCHAIN_ROOT@@/lib;' "$cfg" ||
        ! grep -qxF 'lld_path = @@MOJO_TOOLCHAIN_ROOT@@/bin/lld;' "$cfg"; then
        fail "closure: modular.cfg's shared_libs or lld_path is not what mojo/darwin/mojo_wrapper.sh expects (see $cfg)"
    else
        pass "closure: modular.cfg asks for the one run path the wrapper rewrites; its lld_path names the bin/lld kept as a hedge"
    fi
    bad=""
    for s in gate_runner:gate_runner.sh launcher:launch.sh; do
        if ! cmp -s "$(out "${s%%:*}")" <(cat mojo/darwin/dyld_prelude.sh "mojo/${s#*:}"); then bad="$bad ${s%%:*}"; fi
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
BB="$PWD/mojo/darwin/busybox.sh"
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
sed 's|^exec /usr/bin/cc |printf "[%s]" |' mojo/darwin/cc > "$U/cc"
got=$(sh "$U/cc" -o out -Xlinker -rpath -Xlinker /sandbox/lib x.o -Xlinker -L/l -Wl,-rpath,/q -rpath /z -lm)
if ! grep -q '^exec /usr/bin/cc ' mojo/darwin/cc; then
    fail "cc shim: it no longer ends in exec /usr/bin/cc (update this check)"
elif [ "$got" != "[-Wl,-S][-Wl,-rpath,@loader_path/lib][-o][out][x.o][-Xlinker][-L/l][-lm]" ]; then
    fail "cc shim: rewrote the command line to $got"
else
    pass "cc shim: every run path replaced by @loader_path/lib"
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
sed -e "s|/usr/bin/xcode-select|$H/xcode-select|; s|/usr/bin/xcrun|$H/xcrun|g; s|/usr/bin/cc|$H/cc|" \
    -e "s|/usr/bin/ld|$H/ld|; s|/usr/bin/sw_vers|$H/sw_vers|; s|/sbin/md5|$H/md5|" \
    mojo/darwin/host_identity.sh > "$U/host_identity.sh"
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
cp mojo/darwin/cc "$U/link/cc"
cp "$U/host_identity.sh" "$U/link/host_identity.sh"
printf '0.0-check' > "$U/link/macos_host"
wrap() { (cd "$U/run" && rm -rf .komira_action && sh "$OLDPWD/mojo/darwin/mojo_wrapper.sh" "$BB" "$TC" "$U/link" 11.0 -- build x.mojo -o out > "$U/wrap.txt" 2>&1); }
wrap
rc=$?
rendered="$U/run/.komira_action/modular/modular.cfg"
if [ "$rc" != 2 ] || ! grep -q "this host's identity is '$host_want', the execution platform promises '0.0-check'" "$U/wrap.txt" ||
    ! grep -qxF 'sdk_build=25F71' "$U/wrap.txt"; then
    fail "wrapper: a host without the promised identity was not refused with its fields (rc=$rc, see $U/wrap.txt)"
elif ! grep -qxF 'shared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;' "$rendered" ||
    grep -qF '@@MOJO' "$rendered" || ! grep -qxF "driver_path = $TC/bin/mojo" "$rendered"; then
    fail "wrapper: modular.cfg rendered wrongly (see $rendered)"
else
    # Same SDK version, another toolchain: refused, not matched on the version.
    printf '26.5-ffffffffffffffff' > "$U/link/macos_host"
    wrap
    rc_same_sdk=$?
    printf '%s' "$host_want" > "$U/link/macos_host"
    wrap
    rc=$?
    # The stand-in compiler writes nothing, so a host that passes the identity
    # check reaches the output check (exit 3).
    if [ "$rc_same_sdk" != 2 ]; then
        fail "wrapper: a host with the promised SDK version but another toolchain digest was accepted (rc=$rc_same_sdk)"
    elif [ "$rc" != 3 ] || ! grep -q "compiler exited 0 but out is missing" "$U/wrap.txt"; then
        fail "wrapper: the promised host was not accepted (rc=$rc, see $U/wrap.txt)"
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
                pass "wrapper: refuses an incomplete closure, an unexpected shared_libs and an unpromised host; accepts the promised one; renders @loader_path/lib"
            fi
        fi
    fi
fi

# run_check.sh starts the binary with no library path of any loader.
printf '#!/bin/sh\necho "[${LD_LIBRARY_PATH-}${LD_PRELOAD-}${DYLD_LIBRARY_PATH-}${DYLD_FALLBACK_LIBRARY_PATH-}${DYLD_INSERT_LIBRARIES-}]"\n' > "$U/envbin"
chmod +x "$U/envbin"
if ! (cd "$U" && LD_LIBRARY_PATH=/a LD_PRELOAD=/b DYLD_LIBRARY_PATH=/c DYLD_FALLBACK_LIBRARY_PATH=/d DYLD_INSERT_LIBRARIES=/e \
        sh "$OLDPWD/mojo/run_check.sh" "$BB" envbin env_out.txt) > "$U/run_check.txt" 2>&1; then
    fail "run_check.sh: the stand-in binary did not run (see $U/run_check.txt)"
elif [ "$(cat "$U/env_out.txt")" != "[]" ]; then
    fail "run_check.sh: the binary inherited a library path: $(cat "$U/env_out.txt")"
else
    pass "run_check.sh: the binary starts with no LD_* or DYLD_* library path"
fi

[ "$fails" = 0 ]
