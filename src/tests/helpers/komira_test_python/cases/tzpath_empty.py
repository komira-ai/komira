import zoneinfo

assert zoneinfo.TZPATH == (), "zoneinfo.TZPATH is {!r} with no TZDIR, want ()".format(zoneinfo.TZPATH)
