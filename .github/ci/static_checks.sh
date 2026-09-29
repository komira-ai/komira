#!/usr/bin/env bash
# static_checks.sh -- the checks that need no remote execution and no secret.
#
# usage: .github/ci/static_checks.sh <tools-dir>
#
# CI runs this for every pull request, including one from a fork, which is
# never given farm access (see docs/ci.md). It executes nothing from the
# change except the scripts' own text as data: it lints, it does not run.
#
#   1. Every tracked shell script passes shellcheck at severity warning.
#      Scripts with a shebang are checked as their shebang says; a file with
#      none that names its shell in a `# shellcheck shell=` directive (one
#      sourced by a bash script) as that shell; the rest, which the rules run
#      as `busybox sh <script>`, as busybox.
#   2. The workflows pass actionlint (with shellcheck over their `run:` blocks).
#   3. Every `uses:` in a workflow names a full 40-hex commit SHA, not a tag.
#   4. No committed file configures remote execution: the committed .buckconfig
#      names no endpoint or instance, and .buckconfig.local is gitignored and
#      untracked (CI writes it from a secret at run time).
#   5. Secrets and uploads are fenced (.github/ci/workflow_fences.py): a job
#      that reads a secret names an `environment:`, nothing outside a job
#      reads one, and an artifact upload requires a successful `redact` step.
#
# The linters are downloaded into <tools-dir> and refused unless their sha256
# matches the pins below. SHELLCHECK / ACTIONLINT override the binaries.
set -euo pipefail

SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

# Per-file shellcheck exclusions: path, codes, reason. A row whose file no
# longer exists fails the run, so an exclusion cannot outlive its file.
EXCLUDES=(
    "tools/build/checks/run_checks.sh|SC2046|the audited target list is split into arguments on purpose"
)

[ $# = 1 ] || { echo "usage: $0 <tools-dir>" >&2; exit 2; }
tools=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
mkdir -p "$tools"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

fetch() { # url sha256 out
    curl -fsSL --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --quiet - || { echo "sha256 mismatch: $1" >&2; exit 1; }
}
if [ -z "${SHELLCHECK:-}" ]; then
    fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" \
        "$SHELLCHECK_SHA256" "$tools/shellcheck.tar.xz"
    tar -xJf "$tools/shellcheck.tar.xz" -C "$tools" --strip-components=1 "shellcheck-v$SHELLCHECK_VERSION/shellcheck"
    SHELLCHECK=$tools/shellcheck
fi
if [ -z "${ACTIONLINT:-}" ]; then
    fetch "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        "$ACTIONLINT_SHA256" "$tools/actionlint.tar.gz"
    tar -xzf "$tools/actionlint.tar.gz" -C "$tools" actionlint
    ACTIONLINT=$tools/actionlint
fi

# 1
declare -A exclude=()
for row in "${EXCLUDES[@]}"; do
    IFS='|' read -r path codes _ <<< "$row"
    if [ -f "$path" ]; then exclude[$path]=$codes; else fail "shellcheck: exclusion names $path, which does not exist; delete the row"; fi
done
scripts=0
sc_out=$(mktemp)
while IFS= read -r -d '' f; do
    case "$f" in *.sh) ;; *) head -1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' || continue ;; esac
    scripts=$((scripts + 1))
    args=(-S warning -f gcc)
    [ -n "${exclude[$f]:-}" ] && args+=(-e "${exclude[$f]}")
    # No shebang: a script the rules run as `busybox sh`, unless it names its
    # shell in a directive (a file sourced by a bash script does).
    head -1 "$f" | grep -q '^#!' || head -5 "$f" | grep -q '^# shellcheck shell=' || args+=(-s busybox)
    "$SHELLCHECK" "${args[@]}" "$f" >> "$sc_out" || true
done < <(git ls-files -z)
if [ "$scripts" = 0 ]; then
    fail "shellcheck: found no shell scripts, so checked nothing"
elif [ -s "$sc_out" ]; then
    cat "$sc_out"; fail "shellcheck: $(wc -l < "$sc_out") finding(s) in $scripts scripts"
else
    pass "shellcheck: $scripts scripts"
fi
rm -f "$sc_out"

# 2
if "$ACTIONLINT" -shellcheck "$SHELLCHECK" .github/workflows/*.yml; then
    pass "actionlint: $(ls .github/workflows/*.yml | wc -l) workflow(s)"
else
    fail "actionlint"
fi

# 3
unpinned=$(grep -nE '^\s*(-\s+)?uses:' .github/workflows/*.yml | grep -vE 'uses:\s*[^@[:space:]]+@[0-9a-f]{40}(\s|$)' || true)
total=$(grep -cE '^\s*(-\s+)?uses:' .github/workflows/*.yml | awk -F: '{s += $NF} END {print s + 0}')
if [ -n "$unpinned" ]; then
    echo "$unpinned"; fail "action pins: a \`uses:\` is not pinned to a full commit SHA"
elif [ "$total" = 0 ]; then
    fail "action pins: found no \`uses:\` lines, so checked nothing"
else
    pass "action pins: all $total \`uses:\` pinned to a commit SHA"
fi

# 4
if grep -nE '^\s*(engine_address|action_cache_address|cas_address|address|instance_name|tls_ca_certs|http_headers)\s*=' .buckconfig; then
    fail "remote execution: the committed .buckconfig configures an endpoint; it belongs in .buckconfig.local"
elif git ls-files --error-unmatch .buckconfig.local > /dev/null 2>&1; then
    fail "remote execution: .buckconfig.local is tracked"
elif ! git check-ignore -q .buckconfig.local; then
    fail "remote execution: .buckconfig.local is not gitignored"
else
    pass "remote execution: no committed file names an endpoint"
fi

# 5
if python3 .github/ci/workflow_fences.py .github/workflows/*.yml; then
    pass "fences: secrets only in jobs that name an environment; uploads only after redaction"
else
    fail "fences: a secret or an upload is not fenced"
fi

[ "$fails" = 0 ] || { echo "$fails static check(s) failed"; exit 1; }
echo "all static checks passed"
