#!/bin/sh
# regen_goldens.sh -- writes goldens/named.txt and goldens/footer.txt from
# zdump's reading of a zoneinfo tree. Not run by the build: a person runs it
# by hand when third_party/tzdata's pin moves, and reviews the diff.
#
# usage: regen_goldens.sh <zoneinfo dir> <zones list> <goldens dir>
#
#   <zoneinfo dir>  the extracted src/tzdata/zoneinfo of the pinned archive
#   <zones list>    its src/tzdata/zones (one name per line)
#
# zdump -v prints, for each change of local time, the last second before it
# and the first second of it, each as UT and as local time with isdst= and
# gmtoff=. Each pair becomes one line:
#
#   <zone> <utc seconds> <offset before> <isdst before> <abbr before>
#          <offset after> <isdst after> <abbr after>
#
# named.txt: the zones the calendar plan names, every change from 1800 to
# 2100. footer.txt: every zone of the list, every change in UT years 2037 to
# 2040, which zic's slim files leave to the footer's POSIX TZ string. The
# epoch seconds are computed here from zdump's UT date (days_from_civil, the
# same algorithm as komira_datetime's civil.mojo); no timestamp is parsed by
# the code under test.
set -eu
ZI="$1"; ZONES="$2"; OUT="$3"
NAMED="America/New_York Europe/London Australia/Lord_Howe Asia/Kathmandu America/Sao_Paulo Pacific/Apia"

pairs() {
    # $1 zone, $2 first UT year kept, $3 last UT year kept
    zdump -v -c "$(($2 - 1)),$(($3 + 2))" "$ZI/$1" | awk -v zone="$1" -v lo="$2" -v hi="$3" '
    function days(y, m, d,   era, yoe, mp, doy, doe) {
        if (m <= 2) y -= 1
        era = (y >= 0 ? y : y - 399); era = int(era / 400)
        yoe = y - era * 400
        mp = (m > 2) ? m - 3 : m + 9
        doy = int((153 * mp + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return era * 146097 + doe - 719468
    }
    BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
            for (i = 1; i <= 12; i++) mon[mn[i]] = i; have = 0 }
    $7 == "UT" && $15 ~ /^isdst=/ && $6 >= lo - 1 && $6 <= hi + 1 {
        split($5, t, ":")
        s = days($6, mon[$3], $4) * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
        dst = substr($15, 7); off = substr($16, 8)
        if (have && s == ps + 1 && $6 >= lo && $6 <= hi)
            print zone, s, poff, pdst, pabbr, off, dst, $14
        have = 1; ps = s; poff = off; pdst = dst; pabbr = $14
    }'
}

{
    echo "# zdump -v of the pinned tz release, every change of local time from 1800 to 2100"
    echo "# <zone> <utc seconds> <offset before> <isdst before> <abbr before> <offset after> <isdst after> <abbr after>"
    for z in $NAMED; do pairs "$z" 1800 2100; done
} > "$OUT/named.txt"

{
    echo "# zdump -v of the pinned tz release, every change of local time in UT years 2037 to 2040, every zone"
    echo "# <zone> <utc seconds> <offset before> <isdst before> <abbr before> <offset after> <isdst after> <abbr after>"
    while read -r z; do pairs "$z" 2037 2040; done < "$ZONES"
} > "$OUT/footer.txt"
