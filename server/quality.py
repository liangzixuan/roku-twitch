import json
import re
from urllib.parse import urlsplit

from .storage import read_json, write_json


QUALITY_PATTERN = r"^(best|[0-9]{3,4}p(?:[0-9]{2,3})?)$"


def valid_media_url(url):
    if not isinstance(url, str):
        return False
    try:
        parsed = urlsplit(url)
        host = parsed.hostname or ""
        return (parsed.scheme == "https" and not parsed.username and not parsed.password
                and parsed.port in (None, 443) and not any(c.isspace() for c in url)
                and any(host.endswith(suffix) for suffix in (".cloudfront.net", ".ttvnw.net", ".twitch.tv", ".twitchcdn.net")))
    except ValueError:
        return False


def read_variants(path):
    try:
        if path.stat().st_size > 2_000_000:
            return {}
        streams = json.loads(path.read_text(encoding="utf-8")).get("streams", {})
        variants = {name: stream["url"] for name, stream in streams.items()
                    if re.fullmatch(QUALITY_PATTERN, name) and isinstance(stream, dict)
                    and stream.get("type") == "hls" and valid_media_url(stream.get("url"))}
        if "best" not in variants:
            return {}
        return variants
    except (OSError, ValueError, AttributeError, TypeError):
        return {}


def quality_choices(variants):
    names = [name for name in variants if name != "best"]
    names.sort(key=lambda name: tuple(int(n or 0) for n in name.split("p")), reverse=True)
    return ["best", *names] if variants else []


class QualityPreference:
    def __init__(self, data):
        self.path = data / "quality.json"

    def get(self, user_id):
        value = (read_json(self.path) or {}).get(user_id, "best")
        return value if isinstance(value, str) and re.fullmatch(QUALITY_PATTERN, value) else "best"

    def save(self, user_id, quality):
        accounts = read_json(self.path) or {}
        accounts[user_id] = quality
        write_json(self.path, accounts)
