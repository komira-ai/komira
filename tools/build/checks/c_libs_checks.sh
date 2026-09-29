# shellcheck shell=bash
# c_libs_checks.sh -- checks of the vendored C libraries built without their
# own build systems (third_party/aws-lc, third_party/s2n-tls). Sourced by
# tools/build/checks/run_checks.sh (uses its BUCK2, ROOT, LOG, pass, fail,
# expect_green and expect_red); not run on its own.
#
#  26. aws-lc and s2n-tls:
#      - drift: third_party/<lib>/srcs.bzl is what //third_party/<lib>:srcs_gen
#        (tools/build/third_party_srcs, a Mojo tool) reads out of the pinned
#        archive's CMake lists today (the test //third_party/<lib>:srcs_drift,
#        which `./buck2 test //...` also runs);
#      - libcrypto passes aws-lc's own self tests and SHA-256, AES-128 and
#        ChaCha20 known-answer vectors, called from Mojo on a worker
#        (//tools/build/examples/aws_lc:test_aws_lc[run_check]);
#      - an s2n-tls client and server complete a TLS 1.3 handshake with
#        certificate verification and exchange data, driven from Mojo on a
#        worker (//tools/build/examples/s2n_tls:test_s2n_handshake[run_check]);
#      - s2n-tls's feature defines: every probe named in
#        third_party/s2n-tls/features.bzl compiles (checks//s2n_probes), and
#        every other probe fails to;
#      - neither test binary exports a dynamic symbol (both libraries are
#        compiled with hidden visibility, so nothing in them can interpose on
#        a library the Mojo runtime loads).

for lib in aws-lc s2n-tls; do
    if (cd "$ROOT" && timeout 900 "$BUCK2" test "//third_party/$lib:srcs_drift") > "$LOG/drift_$lib.log" 2>&1; then
        pass "drift $lib: third_party/$lib/srcs.bzl is what //third_party/$lib:srcs_gen reads out of the pinned archive"
    else
        fail "drift $lib: //third_party/$lib:srcs_drift failed (see $LOG/drift_$lib.log)"
    fi
done

expect_green aws_lc_kat "//tools/build/examples/aws_lc:test_aws_lc[run_check]"
expect_green s2n_handshake "//tools/build/examples/s2n_tls:test_s2n_handshake[run_check]"

features=$(grep -o '"S2N_[A-Z0-9_]*"' "$ROOT/third_party/s2n-tls/features.bzl" | tr -d '"')
probes=$(cd "$ROOT" && "$BUCK2" uquery 'kind(cxx_library, checks//s2n_probes:)' 2> "$LOG/s2n_probes_query.log" |
    sed -n 's/.*:probe_//p')
if [ -z "$probes" ] || [ -z "$features" ]; then
    fail "s2n probes: no probes or no features found (see $LOG/s2n_probes_query.log)"
else
    enabled=()
    for f in $features; do enabled+=("checks//s2n_probes:probe_$f"); done
    expect_green s2n_probes_enabled "${enabled[@]}"
    for p in $probes; do
        if ! printf '%s\n' "$features" | grep -qx "$p"; then
            expect_red "s2n_probe_disabled_$p" "error:" "checks//s2n_probes:probe_$p"
        fi
    done
fi

for bin in //tools/build/examples/aws_lc:test_aws_lc //tools/build/examples/s2n_tls:test_s2n_handshake; do
    name=exports_$(basename "${bin#*:}")
    if ! "$BUCK2" build "$bin" --materializations all --show-full-simple-output > "$LOG/$name.txt" 2> "$LOG/$name.log"; then
        fail "$name: cannot build $bin (see $LOG/$name.log)"
        continue
    fi
    exe=$(tail -n 1 "$LOG/$name.txt")
    readelf --dyn-syms -W "$exe" > "$LOG/$name.dynsym.txt" 2>&1
    exported=$(awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && $8 != "" { print $8 }' "$LOG/$name.dynsym.txt")
    if ! grep -q 'Symbol table' "$LOG/$name.dynsym.txt"; then
        fail "$name: readelf read no dynamic symbol table from $exe"
    elif [ -n "$exported" ]; then
        fail "$name: $bin exports $(printf '%s\n' "$exported" | wc -l | tr -d ' ') dynamic symbols, e.g. $(printf '%s\n' "$exported" | head -n 3 | tr '\n' ' ')"
    else
        pass "$name: $bin exports no dynamic symbol"
    fi
done
