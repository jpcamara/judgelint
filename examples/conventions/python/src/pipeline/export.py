import logging
import urllib.request

logger = logging.getLogger(__name__)


def upload(report, url):
    """Upload a report.

    Raises urllib.error.HTTPError if the server answers with an error, and
    urllib.error.URLError if it can't be reached.
    """
    body = report.to_json().encode()
    request = urllib.request.Request(url, data=body, method="POST")
    with urllib.request.urlopen(request) as response:
        logger.info("uploaded report %s: %s", report.id, response.status)
        return response.status
