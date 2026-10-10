"""The bounds the validators enforce. Each is a refusal past it, never a
truncation."""

# A calendar's name.
comptime MAX_NAME_BYTES = 256
# An event's or an override's title.
comptime MAX_TITLE_BYTES = 1024
# An event's or an override's location.
comptime MAX_LOCATION_BYTES = 1024
# An event's or an override's description.
comptime MAX_DESCRIPTION_BYTES = 65536
# An event's uid.
comptime MAX_UID_BYTES = 255
# How many days an all-day event may cover.
comptime MAX_EVENT_DAYS = 366
# How long a timed event may last.
comptime MAX_DURATION_SECONDS = 366 * 86400
# A recurrence's interval (the least is 1).
comptime MAX_INTERVAL = 999
# A recurrence's occurrence count.
comptime MAX_COUNT = 10000
# How many occurrences one event may exclude.
comptime MAX_EXDATES = 1000
# How many reminders one event may carry.
comptime MAX_REMINDERS = 5
# The earliest reminder: four weeks before the start.
comptime MAX_REMINDER_MINUTES = 40320
