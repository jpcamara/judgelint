import logging

logger = logging.getLogger(__name__)


def clean(rows):
    """Drop rows without an id.

    Raises nothing; bad rows are skipped and logged.
    """
    kept = []
    for row in rows:
        if "id" not in row:
            logger.warning("dropping row without id")
            continue
        kept.append(row)
    print(f"kept {len(kept)} of {len(rows)} rows")
    return kept
