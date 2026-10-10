import os
import sys
import zoneinfo

# The zone setup each run gets: TZ=UTC0, and TZDIR (absolute) as zoneinfo's
# only path, or no TZDIR and an empty path. Writes which one it saw.
out = sys.argv[1]
tzdir = os.environ.get("TZDIR")
assert os.environ.get("TZ") == "UTC0", "TZ is {!r}, want 'UTC0'".format(os.environ.get("TZ"))
want_env = {"LC_ALL", "PYTHONHASHSEED", "TZ"} | ({"TZDIR"} if tzdir else set())
assert set(os.environ) == want_env, "environment is {}, want {}".format(sorted(os.environ), sorted(want_env))
if tzdir:
    assert os.path.isabs(tzdir) and os.path.isdir(tzdir), "TZDIR {!r} is not an absolute directory".format(tzdir)
    assert zoneinfo.TZPATH == (tzdir,), "zoneinfo.TZPATH is {!r}, want ({!r},)".format(zoneinfo.TZPATH, tzdir)
    seen = "TZDIR " + os.path.basename(tzdir)
else:
    assert zoneinfo.TZPATH == (), "zoneinfo.TZPATH is {!r} with no TZDIR, want ()".format(zoneinfo.TZPATH)
    seen = "no TZDIR"
with open(os.path.join(out, "tz.txt"), "w") as f:
    f.write(seen + "\n")
