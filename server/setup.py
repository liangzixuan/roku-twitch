import argparse
import getpass
import re
import secrets
import zipfile
from urllib.parse import urlparse

import httpx

from .auth import ID
from .storage import DATA, ROOT, read_json, write_json


def configure():
    old = read_json(DATA / "settings.json") or {}
    print("Use a Twitch application with Client Type set to Public.")
    client_id = input("Twitch Client ID (Enter keeps the current value): ").strip() or old.get("client_id", "")
    if not re.fullmatch(r"[A-Za-z0-9]+", client_id):
        raise SystemExit("Enter the application's Client ID. See README for registration steps.")
    old_roku = read_json(ROOT / "roku/config.json") or {}
    url = input("Computer or NAS LAN URL (for example http://192.168.1.20:58787): ").strip() or old_roku.get("server", "")
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise SystemExit("Enter an HTTP or HTTPS server address without a path, query or password.")
    if old.get("client_id") and client_id != old["client_id"] and (DATA / "account.json").exists():
        raise SystemExit("Sign out before changing the Twitch application Client ID.")
    key = old.get("app_key") or secrets.token_urlsafe(32)
    write_json(DATA / "settings.json", {"client_id": client_id, "app_key": key})
    write_json(ROOT / "roku/config.json", {"server": url.rstrip("/"), "appKey": key})
    package()
    print("Setup saved. Start the server, then install dist/roku-twitch.zip on your Roku.")


def import_playback():
    if not (DATA / "settings.json").exists():
        raise SystemExit("Run setup first.")
    print("Use the Twitch website login token from your own account. Input is hidden.")
    print("Do not paste this token into chat or save it in shared files.")
    token = getpass.getpass("Playback token: ").strip()
    if not re.fullmatch(r"[A-Za-z0-9]{30}", token):
        raise SystemExit("Expected the 30-character Twitch website token.")
    try:
        with httpx.Client(timeout=15, follow_redirects=False) as http:
            r = http.get(f"{ID}/validate", headers={"Authorization": f"OAuth {token}"})
    except httpx.HTTPError:
        raise SystemExit("Cannot reach Twitch. No credential was saved.") from None
    if r.status_code != 200 or not r.json().get("user_id"):
        raise SystemExit("Twitch did not validate this login. No credential was saved.")
    identity = r.json()
    write_json(DATA / "playback.json", {"token": token, "user_id": identity["user_id"], "login": identity["login"]})
    print("Playback login saved locally. Roku will check that both logins use the same account.")


def package():
    if not (ROOT / "roku/config.json").exists():
        raise SystemExit("Run setup before packaging.")
    folder = ROOT / "dist"
    folder.mkdir(exist_ok=True)
    destination = folder / "roku-twitch.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((ROOT / "roku").rglob("*")):
            if path.is_file() and path.name != "config.example.json":
                archive.write(path, path.relative_to(ROOT / "roku"))
    destination.chmod(0o600)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["configure", "import-playback", "package"], nargs="?", default="configure")
    args = parser.parse_args()
    {"configure": configure, "import-playback": import_playback, "package": package}[args.command]()
