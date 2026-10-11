# shellcheck shell=bash
# c_libs_tests.sh -- tests of the vendored C libraries built without their
# own build systems (third_party/aws-lc, third_party/s2n-tls). Sourced by
# tools/build/tests/run_tests.sh (uses its BUCK2, ROOT, LOG, pass, fail,
# expect_green and expect_red); not run on its own.
#
#  26. aws-lc and s2n-tls:
#      - (in the gate: //third_party/<lib>:srcs_drift, the test that
#        third_party/<lib>/srcs.bzl is what //third_party/<lib>:srcs_gen reads
#        out of the pinned archive's CMake lists today);
#      - (in the gate, each a validation of its binary: aws-lc's self tests
#        and known-answer vectors, //tools/build/examples/aws_lc:test_aws_lc;
#        an s2n-tls TLS 1.3 handshake,
#        //tools/build/examples/s2n_tls:test_s2n_handshake);
#      - s2n-tls's feature defines: every other probe than those
#        third_party/s2n-tls/features.bzl names fails to compile
#        (tests//negative/s2n_probes). (Those it names compile:
#        tests//functional/s2n_probes, in the gate; a named feature with no
#        probe is refused at load by third_party/s2n-tls/BUCK.)
#      - neither test binary exports a dynamic symbol (both libraries are
#        compiled with hidden visibility, so nothing in them can interpose on
#        a library the Mojo runtime loads).

features=$(grep -o '"S2N_[A-Z0-9_]*"' "$ROOT/third_party/s2n-tls/features.bzl" | tr -d '"')
probes=$(cd "$ROOT" && "$BUCK2" uquery 'kind(cxx_library, tests//functional/s2n_probes: + tests//negative/s2n_probes:)' 2> "$LOG/s2n_probes_query.log" |
    sed -n 's/.*:probe_//p')
if [ -z "$probes" ] || [ -z "$features" ]; then
    fail "s2n probes: no probes or no features found (see $LOG/s2n_probes_query.log)"
else
    for p in $probes; do
        if ! printf '%s\n' "$features" | grep -qx "$p"; then
            expect_red "s2n_probe_disabled_$p" "error:" "tests//negative/s2n_probes:probe_$p"
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
