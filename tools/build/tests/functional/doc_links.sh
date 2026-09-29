#!/usr/bin/env bash
# doc_links.sh -- every relative link in the repository's Markdown resolves.
#
# usage: tools/build/tests/functional/doc_links.sh [<root>]    (default: the repo root)
#
# <root> must be a git work tree (or a directory inside one); the check needs
# `git` on the client, and builds the Mojo tool that reads the links
# (inspect doc-links, tools/build/inspect) on the farm from this checkout,
# whatever <root> is. Reads every tracked *.md under <root> and
# checks each inline link `[text](target)` and reference definition
# `[id]: target` whose target is relative (not `scheme:`, not `//host`):
#   - the target is a file tracked by git, or a directory holding one,
#     resolved against the linking file's directory: a link to an ignored or
#     untracked file (buck-out/, .buckconfig.local) resolves here and is dead
#     in a fresh clone;
#   - it stays inside <root>, so it also resolves in a fresh clone or on a
#     code host;
#   - a `#fragment` on a Markdown target (or a bare `#fragment`) names a
#     heading in that file (GitHub anchor rules: lower case, punctuation
#     other than `-` and `_` dropped, spaces to `-`, `-N` for repeats).
# Fenced code blocks and inline code are not read. Exits 1 naming every dead
# link, and also when it found no relative link at all (a scan that sees
# nothing proves nothing).
set -euo pipefail

root=${1:-"$(cd "$(dirname "$0")/../../../.." && pwd)"}
[ -d "$root" ] || { echo "doc_links: no directory $root" >&2; exit 2; }
command -v git > /dev/null || { echo "FAIL  doc links: needs \`git\` on the client" >&2; exit 2; }
git -C "$root" rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    || { echo "FAIL  doc links: $root is not inside a git work tree (links are resolved against tracked files)" >&2; exit 2; }
# shellcheck source=tools/build/tests/tool_lib.sh
. "$(dirname "$0")/../tool_lib.sh"
inspect_init || { echo "FAIL  doc links: cannot build the link reader" >&2; exit 2; }

real=$(cd "$root" && pwd -P)
# Paths tracked by git under <root>, relative to it (NUL-separated); the tool
# drops those deleted in the working tree.
list=$(mktemp "${TMPDIR:-/tmp}/komira_doc_links.XXXXXX")
trap 'rm -f "$list"' EXIT
git -C "$real" ls-files -z --cached -- . > "$list"
inspect_tool doc-links "$real" "$list"
