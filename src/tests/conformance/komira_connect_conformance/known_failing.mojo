# =============================================================================
# known_failing.mojo -- every known-failing pattern carries its reason
# =============================================================================
#
# known_failing.txt is the runner's own `--known-failing @file`: one test case
# pattern per line (`*` matches one name component, `**` any number), `#`
# lines are comments, blank lines are ignored. The runner makes the list
# shrink-only by itself: a listed case that passes fails the run ("was
# expected to fail but did not"), and a pattern that matches no case of the
# run fails it too ("unmatched and possibly invalid patterns").
#
# What the runner does not check is the review rule of this package: every
# pattern has a reason. The file is a list of blocks, separated by blank
# lines; a block is one or more `# ` reason lines, then the patterns that
# reason covers. Lines starting `##` are prose about the file as a whole and
# belong to no block. `parse_known_failing` refuses a pattern whose block has no
# reason line before it, a reason with no pattern under it, a block that
# goes back to comments after its patterns, and a pattern listed twice.
# =============================================================================


@fieldwise_init
struct KnownFailing(Copyable, Movable):
    var pattern: String
    var reason: String
    var line: Int


def _is_comment(line: String) -> Bool:
    return line.startswith("#")


def parse_known_failing(text: String) -> Tuple[List[KnownFailing], List[String]]:
    """The patterns with their reasons, and every problem with the file."""
    var entries = List[KnownFailing]()
    var problems = List[String]()
    var reason = String("")
    var reason_line = 0
    var block_has_pattern = False
    var n = 0
    for raw in text.split("\n"):
        n += 1
        var line = String(String(raw).strip())
        if line.byte_length() == 0:
            if reason.byte_length() > 0 and not block_has_pattern:
                problems.append(
                    "line " + String(reason_line) + ": a reason with no pattern under it"
                )
            reason = String("")
            block_has_pattern = False
            continue
        if line.startswith("##"):
            continue  # prose about the file, not a reason
        if _is_comment(line):
            if block_has_pattern:
                problems.append(
                    "line " + String(n)
                    + ": a comment after the block's patterns; start a new block with a blank line"
                )
                continue
            var text_part = String(String(line[byte=1:]).strip())
            if text_part.byte_length() > 0:
                if reason.byte_length() > 0:
                    reason += " "
                else:
                    reason_line = n
                reason += text_part
            continue
        if reason.byte_length() == 0:
            problems.append("line " + String(n) + ": pattern '" + line + "' has no reason above it")
        for ref e in entries:
            if e.pattern == line:
                problems.append(
                    "line " + String(n) + ": pattern '" + line + "' is already listed on line "
                    + String(e.line)
                )
        entries.append(KnownFailing(pattern=line, reason=reason, line=n))
        block_has_pattern = True
    if reason.byte_length() > 0 and not block_has_pattern:
        problems.append("line " + String(reason_line) + ": a reason with no pattern under it")
    return (entries^, problems^)
