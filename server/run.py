from urllib.parse import urlparse

import uvicorn

from .storage import ROOT, read_json


def main():
    config = read_json(ROOT / "roku/config.json")
    if not config:
        raise SystemExit("Run python -m server.setup first.")
    address = urlparse(config["server"])
    if address.scheme != "http":
        raise SystemExit("For HTTPS, configure a TLS reverse proxy and start Uvicorn manually. See README.")
    port = address.port or 80
    uvicorn.run("server.app:app", host="0.0.0.0", port=port, access_log=False)


if __name__ == "__main__":
    main()
