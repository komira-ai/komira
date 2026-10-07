def classify_score(score: Int, bonus: Bool) -> String:
    """A grade with every kind of source decision: `if`, `elif`, `or` and
    `and`. Test 47's test takes some arms and never the first."""
    if score < 0 or score > 100:
        return "invalid"
    elif score >= 90 and bonus:
        return "top"
    elif score >= 90:
        return "high"
    return "pass"
