# host_identity.sh -- the identity of a macOS execution host, as the value of
# its `macos_host` platform property.
#
# usage: sh host_identity.sh            prints the value: <sdk version>-<digest>
#        sh host_identity.sh --fields   prints the fields the digest covers
#
# Run it on each macOS worker to get the value its property set must carry;
# every macOS compile runs it again and refuses (exit 2 in the wrapper) a host
# whose value differs from the one the execution platform promises.
#
# A compile on macOS uses more of the host than its inputs name: the C driver
# and the linker it runs, the SDK, and the operating system whose libraries a
# gated test loads. Two hosts can print the same SDK version and still differ
# in each of those (Xcode.app against the Command Line Tools, an SDK respin at
# the same version, another clang or ld build, another OS build), so the
# property carries a digest of all of them:
#
#   developer_dir  xcode-select -p: Xcode.app or the Command Line Tools
#   sdk_version    xcrun --show-sdk-version
#   sdk_build      xcrun --show-sdk-build-version
#   cc             cc --version, first line (the clang build)
#   ld             ld -v, first line (the linker build)
#   os_build       sw_vers -buildVersion
#
# The value is the SDK version (so a person can tell queues apart), a dash,
# and the first 16 hex digits of the md5 of the field lines. Every tool is
# named by its absolute path; the script needs nothing from PATH but `head`.
# Exit status: 0, or 2 when a field cannot be read.

set -eu

field() { # name, value
    if [ -z "$2" ]; then
        echo "host_identity: REFUSING: cannot read '$1' on this host" >&2
        exit 2
    fi
    printf '%s=%s\n' "$1" "$2"
}

fields() {
    field developer_dir "$(/usr/bin/xcode-select -p 2> /dev/null || true)"
    field sdk_version "$(/usr/bin/xcrun --show-sdk-version 2> /dev/null || true)"
    field sdk_build "$(/usr/bin/xcrun --show-sdk-build-version 2> /dev/null || true)"
    field cc "$(/usr/bin/cc --version 2> /dev/null | head -n 1 || true)"
    field ld "$(/usr/bin/ld -v 2>&1 | head -n 1 || true)"
    field os_build "$(/usr/bin/sw_vers -buildVersion 2> /dev/null || true)"
}

text=$(fields)
if [ "${1:-}" = "--fields" ]; then
    printf '%s\n' "$text"
    exit 0
fi
[ "$#" = 0 ] || { echo "host_identity: usage: sh host_identity.sh [--fields]" >&2; exit 2; }
digest=$(printf '%s\n' "$text" | /sbin/md5 -q)
sdk=$(printf '%s\n' "$text" | while IFS= read -r line; do
    case "$line" in sdk_version=*) printf '%s' "${line#sdk_version=}" ;; esac
done)
case "$digest" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) echo "host_identity: REFUSING: md5 printed '$digest', not a digest" >&2; exit 2 ;;
esac
rest=${digest#????????????????}
printf '%s-%s\n' "$sdk" "${digest%"$rest"}"
