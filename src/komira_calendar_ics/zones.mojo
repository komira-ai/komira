# =============================================================================
# zones.mojo -- where the import and the export get time zone rules.
# =============================================================================
#
# A `ZoneSource` gives the `komira_datetime.Zone` of an IANA name, or raises when it
# knows none. Two are here: `ZoneinfoDirectory` reads a zoneinfo directory
# the caller names (`komira_datetime.load_zone`), and `ZoneTable` holds zones the
# caller built. The name `UTC` is always UTC (`komira_datetime.utc_zone`), whatever
# the source holds.
#
# A TZID is read as an IANA name first. When the source knows no zone of
# that name and the file's VTIMEZONE of that TZID carries X-LIC-LOCATION
# (the IANA name some writers put beside a TZID of their own), that name is
# tried next. Otherwise the TZID is unknown and every event using it is
# refused: an unknown TZID is never read as UTC or as floating time.
# =============================================================================

from komira_datetime import Zone, load_zone, utc_zone


trait ZoneSource:
    """Gives the zone named `name`, or raises when it has none."""

    def zone(self, name: String) raises -> Zone:
        ...


struct ZoneinfoDirectory(ZoneSource, Copyable, Movable):
    """The zones of a zoneinfo directory, one TZif file per IANA name, as zic
    writes it."""

    var path: String

    def __init__(out self, var path: String):
        self.path = path^

    def zone(self, name: String) raises -> Zone:
        """The zone `name` read from `<path>/<name>`; raises for an unknown
        name or a file that is not TZif."""
        return load_zone(self.path, name)


struct ZoneTable(ZoneSource, Copyable, Movable):
    """Zones the caller built, looked up by their exact name."""

    var zones: List[Zone]

    def __init__(out self):
        self.zones = List[Zone]()

    def add(mut self, var zone: Zone):
        """Adds `zone` under its name; a later zone of the same name is never
        found."""
        self.zones.append(zone^)

    def zone(self, name: String) raises -> Zone:
        """The zone called `name`; raises when there is none."""
        for i in range(len(self.zones)):
            if self.zones[i].name == name:
                return self.zones[i].copy()
        raise Error('unknown time zone "' + name + '"')


struct ResolvedZone(Copyable, Movable):
    """A TZID and the IANA name and zone it resolved to."""

    var tzid: String
    var name: String
    var zone: Zone

    def __init__(out self, var tzid: String, var name: String, var zone: Zone):
        self.tzid = tzid^
        self.name = name^
        self.zone = zone^


struct ZoneResolver(Copyable, Movable):
    """The TZIDs of one file: each VTIMEZONE's X-LIC-LOCATION, and every
    TZID resolved so far."""

    var aliases: List[String]
    var locations: List[String]
    var resolved: List[ResolvedZone]

    def __init__(out self):
        self.aliases = List[String]()
        self.locations = List[String]()
        self.resolved = List[ResolvedZone]()

    def add_location(mut self, tzid: String, location: String):
        """Records that the VTIMEZONE of `tzid` names the IANA zone
        `location` (the first one recorded for a TZID is used)."""
        self.aliases.append(tzid.copy())
        self.locations.append(location.copy())

    def location_of(self, tzid: String) -> String:
        """The X-LIC-LOCATION recorded for `tzid`, or empty."""
        for i in range(len(self.aliases)):
            if self.aliases[i] == tzid:
                return self.locations[i].copy()
        return String()

    def resolve[Z: ZoneSource](mut self, tzid: String, zones: Z) raises -> ResolvedZone:
        """The zone of `tzid` (module header); raises naming the TZID when
        neither it nor its X-LIC-LOCATION is a zone `zones` knows."""
        for i in range(len(self.resolved)):
            if self.resolved[i].tzid == tzid:
                return self.resolved[i].copy()
        var got = _lookup(tzid, zones)
        var name = tzid.copy()
        var location = self.location_of(tzid)
        if not got and location.byte_length() > 0:
            got = _lookup(location, zones)
            name = location.copy()
        if not got:
            var why = 'TZID "' + tzid + '" names no time zone known here'
            if location.byte_length() > 0:
                why += ', nor does its VTIMEZONE\'s X-LIC-LOCATION "' + location + '"'
            raise Error(why)
        var r = ResolvedZone(tzid.copy(), name^, got.take())
        self.resolved.append(r.copy())
        return r^


def _lookup[Z: ZoneSource](name: String, zones: Z) -> Optional[Zone]:
    try:
        if name == "UTC":
            return utc_zone()
        return zones.zone(name)
    except:
        return None
