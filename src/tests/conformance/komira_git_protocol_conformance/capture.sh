#!/bin/sh
# Records what the pinned git (//third_party/git) says on the wire, one
# build action of the `git_transcripts` rule (defs.bzl):
#   sh capture.sh <busybox> <git_dir> <out_dir>
# Every exchange runs real git on both ends over file://. The client is
# told to start the server through a wrapper (--upload-pack, --receive-pack)
# that copies the bytes each way with tee, so each scenario directory holds
# the exact bytes:
#   conn<n>.req   everything the git client wrote on its n-th connection
#   conn<n>.resp  everything the git server wrote back on it
# and the server repository's state just before the exchange (the inputs a
# server under test needs to answer the same requests):
#   refs.txt     <id> <refname> <peeled id or -> for every ref
#   head.txt     what HEAD names (`git symbolic-ref HEAD`)
#   objects.txt  <id> <type> for every object
#   parents.txt  <commit> <parent>... for every commit (`git rev-list --all --parents`)
#   tags.txt     <tag id> <object id> for every annotated tag
# Fetch scenarios add the client's shallow list before and after
# (shallow_before.txt, shallow_after.txt); push scenarios add the server's
# repository after the push (parents_after.txt) and its settings
# (settings.txt: push-options, deny-non-fast-forwards).
#
# Scenarios (protocol v2 for fetch; receive-pack is always v0):
#   v2_clone      clone of a repository with two branches and two tags
#   v2_fetch      fetch of one new commit, with haves and a server option
#   v2_shallow    clone --depth 1
#   v2_deepen     fetch --deepen 1 in that shallow clone
#   v2_since      clone --single-branch of main with --shallow-since and
#                 --shallow-exclude (deepen-since, deepen-not)
#   v2_unborn     clone of an empty repository (ls-refs unborn)
#   v2_negotiate  fetch --negotiate-only (wait-for-done)
#   push_atomic   push --atomic with push options: an update, a create, a delete
#   push_reject   push --atomic --force refused by receive.denyNonFastForwards
#   push_delete   a delete-only push (no pack), default advertisement
#   push_ff       with receive.denyNonFastForwards: a fast-forward of
#                 refs/heads/main and a forced update of refs/review/side,
#                 both accepted (git refuses non-fast-forwards under
#                 refs/heads/ only)
#   push_empty    the first push into an empty repository
# Exits 1 on the first command that fails, naming it.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
DIST=$(abs "$2")
OUT=$(abs "$3")

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.git_capture" ;;
    /*) T="$BUCK_SCRATCH_PATH/git_capture" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/git_capture" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
HOME="$T/home"
export PATH LC_ALL=C HOME
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
export GIT_AUTHOR_NAME="A U Thor" GIT_AUTHOR_EMAIL=author@example.com
export GIT_COMMITTER_NAME="C O Mitter" GIT_COMMITTER_EMAIL=committer@example.com
GIT="$DIST/bin/git"
mkdir -p "$OUT"

red() {
    echo "git capture RED: $*" >&2
    [ -f "$T/log" ] && { echo "--- log:" >&2; tail -n 40 "$T/log" >&2; }
    exit 1
}

# The wrappers git starts as the server. KGC_CAPTURE names the scenario
# directory; git passes its environment to the server it starts. One git
# command may connect more than once (a fetch that follows tags opens a
# second connection), so connection n is recorded as conn<n>.req and
# conn<n>.resp.
for svc in upload-pack receive-pack; do
    # shellcheck disable=SC2016 # the $ expressions are the wrapper's, expanded when it runs
    printf '#!%s/sh\nn=1\nwhile [ -e "$KGC_CAPTURE/conn$n.req" ]; do n=$((n + 1)); done\ntee "$KGC_CAPTURE/conn$n.req" | "%s" %s "$@" | tee "$KGC_CAPTURE/conn$n.resp"\n' \
        "$T/bin" "$GIT" "$svc" >"$T/$svc"
    chmod 755 "$T/$svc"
done
UP="$T/upload-pack"
RP="$T/receive-pack"

# Commit n: one new file, author and committer dates 1790000000 + 60n.
N=0
commit() {
    N=$((N + 1))
    printf '%s\n' "$2" >"$1/f$N.txt"
    "$GIT" -C "$1" add "f$N.txt" >"$T/log" 2>&1 || red "git add in $1"
    d="$((1790000000 + 60 * N)) +0000"
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" "$GIT" -C "$1" commit -q -m "$2" >"$T/log" 2>&1 ||
        red "git commit '$2' in $1"
}

# The state of repository $1 into scenario directory $2.
state() {
    "$GIT" -C "$1" for-each-ref --format='%(objectname) %(refname) %(*objectname)' >"$T/refs" 2>"$T/log" ||
        red "for-each-ref in $1"
    awk '{ print $1, $2, (NF > 2 ? $3 : "-") }' "$T/refs" >"$2/refs.txt"
    "$GIT" -C "$1" symbolic-ref HEAD >"$2/head.txt" 2>"$T/log" || red "symbolic-ref HEAD in $1"
    "$GIT" -C "$1" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' >"$2/objects.txt" 2>"$T/log" ||
        red "cat-file --batch-all-objects in $1"
    "$GIT" -C "$1" rev-list --all --parents >"$2/parents.txt" 2>"$T/log" || red "rev-list in $1"
    : >"$2/tags.txt"
    awk '$2 == "tag" { print $1 }' "$2/objects.txt" | while read -r tag; do
        target=$("$GIT" -C "$1" cat-file tag "$tag" | awk 'NR == 1 { print $2 }') || red "cat-file tag $tag"
        echo "$tag $target" >>"$2/tags.txt"
    done
}

shallow_of() {
    if [ -f "$1/.git/shallow" ]; then cat "$1/.git/shallow"; fi
}

scenario() {
    KGC_CAPTURE="$OUT/$1"
    export KGC_CAPTURE
    mkdir -p "$KGC_CAPTURE"
}

finish() {
    [ -s "$KGC_CAPTURE/conn1.req" ] || red "$1: the client wrote nothing"
    [ -s "$KGC_CAPTURE/conn1.resp" ] || red "$1: the server wrote nothing"
}

SRC="$T/src"
"$GIT" init -q -b main "$SRC" >"$T/log" 2>&1 || red "git init src"
commit "$SRC" c1
GIT_COMMITTER_DATE="1790000090 +0000" "$GIT" -C "$SRC" tag -a v1 -m "release v1" >"$T/log" 2>&1 || red "git tag -a v1"
commit "$SRC" c2
"$GIT" -C "$SRC" branch topic >"$T/log" 2>&1 || red "git branch topic"
commit "$SRC" c3
"$GIT" -C "$SRC" tag light >"$T/log" 2>&1 || red "git tag light"
"$GIT" -C "$SRC" checkout -q topic >"$T/log" 2>&1 || red "git checkout topic"
commit "$SRC" c4
"$GIT" -C "$SRC" checkout -q main >"$T/log" 2>&1 || red "git checkout main"

# ---- protocol v2 fetch -------------------------------------------------------

scenario v2_clone
state "$SRC" "$KGC_CAPTURE"
"$GIT" -c protocol.version=2 clone -q --no-local --upload-pack="$UP" "file://$SRC" "$T/clone" >"$T/log" 2>&1 ||
    red "v2_clone: git clone"
finish v2_clone
"$GIT" -C "$T/clone" config remote.origin.uploadpack "$UP" >"$T/log" 2>&1 || red "config uploadpack"

scenario v2_fetch
commit "$SRC" c5
state "$SRC" "$KGC_CAPTURE"
"$GIT" -C "$T/clone" -c protocol.version=2 fetch -q -o opt-a origin >"$T/log" 2>&1 || red "v2_fetch: git fetch"
finish v2_fetch

scenario v2_shallow
state "$SRC" "$KGC_CAPTURE"
"$GIT" -c protocol.version=2 clone -q --no-local --depth 1 --upload-pack="$UP" "file://$SRC" "$T/shallow" >"$T/log" 2>&1 ||
    red "v2_shallow: git clone --depth 1"
: >"$KGC_CAPTURE/shallow_before.txt"
shallow_of "$T/shallow" >"$KGC_CAPTURE/shallow_after.txt"
finish v2_shallow
"$GIT" -C "$T/shallow" config remote.origin.uploadpack "$UP" >"$T/log" 2>&1 || red "config uploadpack"

scenario v2_deepen
state "$SRC" "$KGC_CAPTURE"
shallow_of "$T/shallow" >"$KGC_CAPTURE/shallow_before.txt"
"$GIT" -C "$T/shallow" -c protocol.version=2 fetch -q --deepen 1 origin >"$T/log" 2>&1 || red "v2_deepen: git fetch --deepen 1"
shallow_of "$T/shallow" >"$KGC_CAPTURE/shallow_after.txt"
finish v2_deepen

scenario v2_since
state "$SRC" "$KGC_CAPTURE"
"$GIT" -c protocol.version=2 clone -q --no-local --single-branch --branch main \
    --shallow-since="@1790000150 +0000" --shallow-exclude=v1 \
    --upload-pack="$UP" "file://$SRC" "$T/since" >"$T/log" 2>&1 ||
    red "v2_since: git clone --shallow-since --shallow-exclude"
: >"$KGC_CAPTURE/shallow_before.txt"
shallow_of "$T/since" >"$KGC_CAPTURE/shallow_after.txt"
finish v2_since

scenario v2_unborn
"$GIT" init -q --bare -b main "$T/empty.git" >"$T/log" 2>&1 || red "git init --bare empty"
state "$T/empty.git" "$KGC_CAPTURE"
"$GIT" -c protocol.version=2 clone -q --no-local --upload-pack="$UP" "file://$T/empty.git" "$T/empty_clone" >"$T/log" 2>&1 ||
    red "v2_unborn: git clone of an empty repository"
finish v2_unborn

scenario v2_negotiate
state "$SRC" "$KGC_CAPTURE"
tip=$("$GIT" -C "$T/clone" rev-parse refs/remotes/origin/main) || red "rev-parse origin/main"
"$GIT" -C "$T/clone" -c protocol.version=2 fetch --negotiate-only --negotiation-tip="$tip" origin >"$T/log" 2>&1 ||
    red "v2_negotiate: git fetch --negotiate-only"
finish v2_negotiate

# ---- receive-pack ------------------------------------------------------------

DST="$T/dst.git"
"$GIT" init -q --bare -b main "$DST" >"$T/log" 2>&1 || red "git init --bare dst"
"$GIT" -C "$SRC" push -q "file://$DST" main topic >"$T/log" 2>&1 || red "seed push to dst"

scenario push_atomic
"$GIT" -C "$DST" config receive.advertisePushOptions true >"$T/log" 2>&1 || red "config advertisePushOptions"
echo push-options >"$KGC_CAPTURE/settings.txt"
state "$DST" "$KGC_CAPTURE"
commit "$SRC" c6
"$GIT" -C "$SRC" push -q --atomic -o ci.skip -o note=two --receive-pack="$RP" "file://$DST" \
    main main:refs/heads/feature :refs/heads/topic >"$T/log" 2>&1 || red "push_atomic: git push --atomic"
"$GIT" -C "$DST" rev-list --all --parents >"$KGC_CAPTURE/parents_after.txt" 2>"$T/log" || red "rev-list dst"
finish push_atomic

scenario push_reject
"$GIT" -C "$DST" config receive.denyNonFastForwards true >"$T/log" 2>&1 || red "config denyNonFastForwards"
printf 'push-options\ndeny-non-fast-forwards\n' >"$KGC_CAPTURE/settings.txt"
state "$DST" "$KGC_CAPTURE"
"$GIT" -C "$SRC" checkout -q -b side topic >"$T/log" 2>&1 || red "git checkout -b side"
commit "$SRC" c7
if "$GIT" -C "$SRC" push -q --atomic --force --receive-pack="$RP" "file://$DST" \
    side:refs/heads/main side:refs/heads/fresh >"$T/log" 2>&1; then
    red "push_reject: the non-fast-forward push was accepted"
fi
"$GIT" -C "$DST" rev-list --all --parents >"$KGC_CAPTURE/parents_after.txt" 2>"$T/log" || red "rev-list dst"
"$GIT" -C "$SRC" checkout -q main >"$T/log" 2>&1 || red "git checkout main"
finish push_reject

scenario push_delete
"$GIT" -C "$DST" config receive.advertisePushOptions false >"$T/log" 2>&1 || red "config advertisePushOptions"
echo deny-non-fast-forwards >"$KGC_CAPTURE/settings.txt"
state "$DST" "$KGC_CAPTURE"
"$GIT" -C "$SRC" push -q --receive-pack="$RP" "file://$DST" :refs/heads/feature >"$T/log" 2>&1 ||
    red "push_delete: git push of a delete"
"$GIT" -C "$DST" rev-list --all --parents >"$KGC_CAPTURE/parents_after.txt" 2>"$T/log" || red "rev-list dst"
finish push_delete

scenario push_ff
echo deny-non-fast-forwards >"$KGC_CAPTURE/settings.txt"
"$GIT" -C "$SRC" push -q "file://$DST" side:refs/review/side >"$T/log" 2>&1 || red "seed push of refs/review/side"
state "$DST" "$KGC_CAPTURE"
commit "$SRC" c8
"$GIT" -C "$SRC" push -q --receive-pack="$RP" "file://$DST" main +main:refs/review/side >"$T/log" 2>&1 ||
    red "push_ff: git push of a fast-forward and a forced update outside refs/heads/"
"$GIT" -C "$DST" rev-list --all --parents >"$KGC_CAPTURE/parents_after.txt" 2>"$T/log" || red "rev-list dst"
finish push_ff

scenario push_empty
"$GIT" init -q --bare -b main "$T/empty2.git" >"$T/log" 2>&1 || red "git init --bare empty2"
: >"$KGC_CAPTURE/settings.txt"
state "$T/empty2.git" "$KGC_CAPTURE"
"$GIT" -C "$SRC" push -q --receive-pack="$RP" "file://$T/empty2.git" main >"$T/log" 2>&1 ||
    red "push_empty: git push into an empty repository"
"$GIT" -C "$T/empty2.git" rev-list --all --parents >"$KGC_CAPTURE/parents_after.txt" 2>"$T/log" || red "rev-list empty2"
finish push_empty

"$GIT" --version >"$OUT/git_version.txt" 2>"$T/log" || red "git --version"
