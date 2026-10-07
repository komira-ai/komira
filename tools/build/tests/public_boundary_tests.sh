# shellcheck shell=bash
# public_boundary_tests.sh -- test 44, the public boundary lint
# (tools/build/lint/defs.bzl, public_boundary; the reader
# tools/build/lint/public_boundary.awk). Sourced by
# tools/build/tests/run_tests.sh (uses its expect_green and expect_red); not
# run on its own.
#
#  44. //:public_boundary (every file of the repository, against
#      tests/public_boundary_holds.tsv and tests/public_boundary_hosts.tsv) and
#      tests//functional/public_boundary:ok (a planted tree whose every finding
#      is held at its exact count, beside near misses, and binary
#      data) build; each target of tests//negative/public_boundary fails
#      naming its one planted finding (each rule in each spelling, an email
#      address after `mailto:`, in a URL's path and after a URL's user, which
#      is none on a host of the hosts ledger, and a URL's user before a host
#      no row names (s3://, git+ssh://), a date in a third_party BUCK file and
#      C header, a `//` comment after a string holding `//`, a date, home
#      directory or deny-list word in a path, the path of binary data, a file
#      given by `paths`, one finding over a hold, a word of a deny list) or
#      ledger defect (a row for binary data among them, and a row holding a
#      deny-list word), a window with month 13 or not ending on the first day
#      of a month is refused, the root target's window is pinned (uquery of
#      window_from and public_from), an empty tree fails as checking nothing,
#      and a target naming no tree is refused at analysis. The
#      planted tree's window is 2030 to 2031-09-01, so no file of it holds a
#      date of the root target's window.

expect_green public_boundary //:public_boundary tests//functional/public_boundary:ok
N=tests//negative/public_boundary
M="$N/docs/plant.md:1"
HS="tests//functional/public_boundary:hosts.tsv"
for want in \
    "date_iso|$M: date: 2031-08-31 -- a date before 2031-09-01" \
    "date_underscore|$M: date: 2031_08_31 -- " \
    "date_compact|$M: date: 20310831 -- " \
    "date_year_month|$M: date: 2031-08 -- " \
    "date_month_name|$M: date: aug 31, 2031 -- " \
    "date_day_month|$M: date: 31 august 2031 -- " \
    "date_month_year|$M: date: august 2030 -- " \
    "date_numeric|$M: date: 8/31/2031 -- " \
    "date_unpadded|$M: date: 2031-8-31 -- " \
    "date_dmy_dash|$M: date: 31-08-2031 -- " \
    "home_linux|$M: home_path: /home/jdoe -- " \
    "home_mac|$M: home_path: /Users/jdoe -- " \
    "home_windows|$M: home_path: Users\\jdoe -- " \
    "ip_private|$M: ip: 10.1.2.3 -- " \
    "ip_shared|$M: ip: 100.100.1.2 -- " \
    "ip_link_local|$M: ip: 169.254.1.1 -- " \
    "ip_port|$M: ip: 8.8.4.4 -- " \
    "host_single|$M: host: builder -- " \
    "host_unlisted|$M: host: build.corp.zz -- a URL host that is neither a reserved example name nor under a domain of $HS" \
    "host_private|$M: host: svc.corp.internal -- " \
    "host_ipv6|$M: host: [2001:db8::1] -- " \
    "email|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "email_mailto|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "email_url_path|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "email_after_url|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "email_s3_user|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "email_git_ssh_user|$M: email: jdoe@corp.zz -- an email address outside the reserved example domains" \
    "sha_md|$M: commit_sha: 1a2b3c4d -- " \
    "sha_comment|$N/src/komira_a/plant.mojo:1: commit_sha: 9f8e7d6c5b -- " \
    "sha_docstring|$N/src/komira_a/plant.mojo:3: commit_sha: 9f8e7d6c5b -- " \
    "sha_c|$N/src/komira_a/plant.c:1: commit_sha: 9f8e7d6c5b -- " \
    "sha_c_after_string|$N/src/komira_a/plant.c:1: commit_sha: 9f8e7d6c5b -- " \
    "third_party_buck|$N/third_party/up/BUCK:3: date: 2031-08-31 -- " \
    "third_party_c|$N/third_party/up/config.h:1: date: 2031-08-31 -- " \
    "path_date|$N/docs/notes_2031_08_31.md:0: date: 2031_08_31 (in the path) -- " \
    "path_home|$N/home/jdoe/notes.md:0: home_path: /home/jdoe (in the path) -- " \
    "path_deny|$N/docs/zanzibar_notes.md:0: deny: zanzibar (in the path) -- " \
    "path_binary|$N/src/komira_a/tests/fixtures/2031-08-31.arrow:0: date: 2031-08-31 (in the path) -- " \
    "paths_attr|$N/other/.config:1: date: 2031-08-31 -- " \
    "held_new_site|$N/src/komira_a/held.mojo:10: date: 2031.08.31 -- a date before 2031-09-01, when the public history starts (16 findings, held 15)" \
    "deny|$M: deny: zanzibar -- a word of the private deny list" \
    "deny_held|$N/holds_deny.tsv:10: unknown rule \`deny\`" \
    "holds_malformed|$N/holds_malformed.tsv:10: a row has 4 tab-separated fields (rule, file, count, reason), not 3" \
    "holds_rule|$N/holds_rule.tsv:10: unknown rule \`date_time\`" \
    "holds_file|$N/holds_file.tsv:10: src/komira_a/gone.mojo is not a file of the tree; delete the row" \
    "holds_binary|$N/holds_binary.tsv:10: date in src/komira_a/tests/fixtures/data.arrow is held at 1 and has 0: delete the row" \
    "holds_count|$N/holds_count.tsv:10: count \`0\` is not a positive whole number" \
    "holds_reason|$N/holds_reason.tsv:10: empty reason" \
    "holds_duplicate|$N/holds_duplicate.tsv:10: a second row for date in src/komira_a/held.mojo" \
    "holds_lower|$N/holds_lower.tsv:3: date in src/komira_a/held.mojo is held at 16 and has 15: lower the count to 15" \
    "holds_delete|$N/holds_delete.tsv:10: date in docs/near.md is held at 1 and has 0: delete the row" \
    "hosts_malformed|$N/hosts_malformed.tsv:5: a row has 2 tab-separated fields (domain, reason), not 1" \
    "hosts_reason|$N/hosts_reason.tsv:5: empty reason" \
    "hosts_reserved|$N/hosts_reserved.tsv:5: example.com is reserved for examples and needs no row; delete the row" \
    "hosts_duplicate|$N/hosts_duplicate.tsv:5: a second row for amazonaws.com" \
    "hosts_unused|$N/hosts_unused.tsv:5: no URL host of the tree is unused.zz or under it; delete the row" \
    "window_month|public_boundary: the window is from year \`2030\` to \`2031-13-01\`" \
    "window_bad|public_boundary: the window is from year \`2030\` to \`2031-09-15\`; name a year and a later first day of a month (YYYY-MM-01)" \
    "empty|public_boundary: checked nothing"; do
    expect_red "public_boundary_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done
# The root target's window is the public rule's: from 2025 up to 2026-09-01.
# Narrowing it would let a date through, so it is pinned here.
pbw_rc=0
(cd "$ROOT" && "$BUCK2" uquery //:public_boundary --output-attribute public_from --output-attribute window_from) > "$LOG/public_boundary_window.log" 2>&1 || pbw_rc=$?
if [ "$pbw_rc" = 0 ] && grep -q '"public_from": "2026-09-01"' "$LOG/public_boundary_window.log" && grep -q '"window_from": 2025' "$LOG/public_boundary_window.log"; then
    pass public_boundary_window
else
    fail "public_boundary_window: //:public_boundary does not read from 2025 up to 2026-09-01 (see $LOG/public_boundary_window.log)"
fi
expect_red public_boundary_no_tree "name the files in exactly one of \`tree\` and \`files\`" "$N:no_tree"
expect_red public_boundary_both_tree_and_files "name the files in exactly one of \`tree\` and \`files\`" "$N:both_tree_and_files"
