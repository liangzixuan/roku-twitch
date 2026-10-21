import math
import re
import secrets
import time
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from .storage import read_json, write_json


ID = "https://id.twitch.tv/oauth2"
API = "https://api.twitch.tv/helix"
SCOPE = "user:read:subscriptions"
FOLLOW_SCOPE = "user:read:follows"
LOGIN_SCOPES = SCOPE + " " + FOLLOW_SCOPE


class Auth:
    # The app serializes calls to this object with its state lock.
    def __init__(self, data, client_id, http=None, clock=time.time):
        self.data = data
        self.client_id = client_id
        self.http = http or httpx.Client(timeout=15, follow_redirects=False)
        self.clock = clock
        self.token = read_json(data / "account.json")
        self.identity = None
        self.checked_at = 0
        self.pending = None
        self.avatar_cache = {}
        self.on_clear = lambda: None

    def request(self, method, url, **kwargs):
        try:
            return self.http.request(method, url, **kwargs)
        except httpx.HTTPError:
            raise HTTPException(502, "Cannot reach Twitch. Try again.") from None

    def clear_account(self):
        self.on_clear()
        self.token = self.identity = None
        self.checked_at = 0
        (self.data / "account.json").unlink(missing_ok=True)

    def start(self):
        if not self.client_id:
            raise HTTPException(503, "Run setup and enter a Twitch public application Client ID.")
        expected_user = None
        if self.token:
            identity = self.validate()
            if FOLLOW_SCOPE in identity.get("scopes", []):
                raise HTTPException(409, "Already signed in. Return to Following.")
            expected_user = identity["user_id"]
        r = self.request("POST", f"{ID}/device", data={"client_id": self.client_id, "scopes": LOGIN_SCOPES})
        if r.status_code != 200:
            raise HTTPException(502, "Twitch could not start login. Check the public application Client ID.")
        d = r.json()
        interval = max(5, int(d.get("interval", 5)))
        self.pending = {**d, "expected_user": expected_user, "id": secrets.token_urlsafe(24),
                        "expires_at": self.clock() + d["expires_in"],
                        "next_poll": self.clock() + interval, "interval": interval}
        return {k: self.pending[k] for k in ("id", "user_code", "verification_uri", "expires_in", "interval")}

    def poll(self, login_id):
        p = self.pending
        if not p or not secrets.compare_digest(p["id"], login_id):
            raise HTTPException(404, "Login request not found. Start login again.")
        if self.clock() >= p["expires_at"]:
            self.pending = None
            return {"state": "expired"}
        if self.clock() < p["next_poll"]:
            return {"state": "pending", "interval": max(1, math.ceil(p["next_poll"] - self.clock()))}
        p["next_poll"] = self.clock() + p["interval"]
        if "candidate" not in p:
            r = self.request("POST", f"{ID}/token", data={
                "client_id": self.client_id, "device_code": p["device_code"], "scopes": LOGIN_SCOPES,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
            if r.status_code == 200:
                p["candidate"] = r.json()
        if "candidate" in p:
            candidate = p["candidate"]
            checked = self.request("GET", f"{ID}/validate", headers={
                "Authorization": f"OAuth {candidate['access_token']}"})
            if checked.status_code != 200:
                raise HTTPException(502, "Cannot verify the new login. Try again.")
            identity = checked.json()
            scopes = identity.get("scopes", [])
            if (identity.get("client_id") != self.client_id or not identity.get("user_id")
                    or SCOPE not in scopes or FOLLOW_SCOPE not in scopes):
                self.pending = None
                raise HTTPException(403, "Allow subscription and followed-channel access, then try again.")
            if p.get("expected_user") and identity["user_id"] != p["expected_user"]:
                self.pending = None
                raise HTTPException(409, "Use the same Twitch account to enable Following. Your existing login was kept.")
            write_json(self.data / "account.json", candidate)
            self.token = candidate
            self.identity, self.checked_at = identity, self.clock()
            self.pending = None
            return {"state": "complete", "login": identity["login"]}
        if r.status_code >= 500:
            raise HTTPException(502, "Twitch login is temporarily unavailable. Try again.")
        d = r.json()
        error = d.get("message", d.get("error", ""))
        if r.status_code == 429 or error == "slow_down":
            p["interval"] += 5
            p["next_poll"] = self.clock() + p["interval"]
            return {"state": "pending", "interval": p["interval"]}
        if error == "authorization_pending":
            return {"state": "pending", "interval": p["interval"]}
        self.pending = None
        return {"state": "denied" if error == "access_denied" else "expired"}

    def refresh(self):
        r = self.request("POST", f"{ID}/token", data={
            "client_id": self.client_id, "grant_type": "refresh_token",
            "refresh_token": self.token["refresh_token"]})
        if r.status_code in (400, 401):
            self.clear_account()
            raise HTTPException(401, "Twitch authorization expired. Sign in again.")
        if r.status_code != 200:
            raise HTTPException(502, "Cannot refresh Twitch login. Try again.")
        self.token = r.json()
        write_json(self.data / "account.json", self.token)
        self.identity = None

    def validate(self, force=False):
        if not self.token:
            raise HTTPException(401, "Sign in to Twitch first.")
        if self.identity and not force and self.clock() - self.checked_at < 3500:
            return self.identity
        r = self.request("GET", f"{ID}/validate", headers={"Authorization": f"OAuth {self.token['access_token']}"})
        if r.status_code == 401:
            self.refresh()
            r = self.request("GET", f"{ID}/validate", headers={"Authorization": f"OAuth {self.token['access_token']}"})
        if r.status_code == 401:
            self.clear_account()
            raise HTTPException(401, "Twitch authorization expired. Sign in again.")
        if r.status_code != 200:
            raise HTTPException(502, "Cannot verify Twitch login. Try again.")
        d = r.json()
        if d.get("client_id") != self.client_id or not d.get("user_id") or SCOPE not in d.get("scopes", []):
            self.clear_account()
            raise HTTPException(401, "Login needs subscription permission. Sign in again.")
        self.identity, self.checked_at = d, self.clock()
        return d

    def helix(self, endpoint, params):
        self.validate()
        for attempt in range(2):
            r = self.request("GET", f"{API}/{endpoint}", params=params, headers={
                "Authorization": f"Bearer {self.token['access_token']}", "Client-Id": self.client_id})
            if r.status_code != 401:
                return r
            if attempt == 0:
                self.validate(force=True)
        self.clear_account()
        raise HTTPException(401, "Twitch authorization expired. Sign in again.")

    def subscription(self, channel):
        identity = self.validate()
        r = self.helix("users", {"login": channel})
        if r.status_code != 200:
            raise HTTPException(502, "Cannot look up the channel. Try again.")
        users = r.json()["data"]
        if not users:
            raise HTTPException(404, "Channel not found.")
        r = self.helix("subscriptions/user", {"broadcaster_id": users[0]["id"], "user_id": identity["user_id"]})
        if r.status_code == 404:
            return {"channel": channel, "subscribed": False, "ad_free": "unverified"}
        if r.status_code != 200:
            raise HTTPException(502, "Cannot check the subscription. Try again.")
        return {"channel": channel, "subscribed": bool(r.json()["data"]), "ad_free": "unverified"}

    def avatars(self, ids):
        now = self.clock()
        self.avatar_cache = {key: value for key, value in self.avatar_cache.items() if now - value[0] < 3600}
        missing = [user_id for user_id in ids if user_id not in self.avatar_cache]
        if missing:
            # Avatars are optional. A CDN or profile failure must not hide followed channels.
            try:
                response = self.helix("users", {"id": missing})
            except HTTPException as exc:
                if exc.status_code == 401:
                    raise
                response = None
            if response is not None and response.status_code == 200:
                profiles = {p["id"]: p.get("profile_image_url", "") for p in response.json().get("data", [])}
                for user_id in missing:
                    url = profiles.get(user_id, "")
                    try:
                        parsed = urlsplit(url)
                        valid = (parsed.scheme == "https" and parsed.hostname == "static-cdn.jtvnw.net"
                                 and parsed.port in (None, 443) and not parsed.username and not parsed.password)
                    except ValueError:
                        valid = False
                    if not valid:
                        url = ""
                    self.avatar_cache[user_id] = (now, url)
        return {user_id: self.avatar_cache.get(user_id, (0, ""))[1] for user_id in ids}

    def follows(self, cursor=""):
        identity = self.validate()
        if FOLLOW_SCOPE not in identity.get("scopes", []):
            raise HTTPException(403, "Enable Following to allow Twitch to share your followed channels.")
        params = {"user_id": identity["user_id"], "first": 100}
        if cursor:
            params["after"] = cursor
        response = self.helix("channels/followed", params)
        if response.status_code != 200:
            raise HTTPException(502, "Cannot load followed channels. Try again.")
        page = response.json()
        follows = page.get("data", [])
        streams = {}
        if follows:
            response = self.helix("streams", {"user_id": [f["broadcaster_id"] for f in follows], "first": 100})
            if response.status_code != 200:
                raise HTTPException(502, "Cannot check live channels. Try again.")
            streams = {s["user_id"]: s for s in response.json().get("data", [])}
        avatars = self.avatars([f["broadcaster_id"] for f in follows]) if follows else {}
        channels = []
        for follow in follows:
            stream = streams.get(follow["broadcaster_id"])
            channels.append({"id": follow["broadcaster_id"], "login": follow["broadcaster_login"],
                             "name": follow["broadcaster_name"], "live": stream is not None,
                             "viewers": stream.get("viewer_count", 0) if stream else 0,
                             "avatar": avatars.get(follow["broadcaster_id"], ""),
                             "title": stream.get("title", "") if stream else "",
                             "game": stream.get("game_name", "") if stream else ""})
        return {"channels": channels, "cursor": page.get("pagination", {}).get("cursor", "")}

    def search_channels(self, query, cursor=""):
        params = {"query": query, "first": 20, "live_only": "false"}
        if cursor:
            params["after"] = cursor
        response = self.helix("search/channels", params)
        if response.status_code != 200:
            raise HTTPException(502, "Cannot search channels. Try again.")
        page = response.json()
        channels = [{"id": c["id"], "login": c["broadcaster_login"],
                     "name": c["display_name"], "live": bool(c.get("is_live")),
                     "title": c.get("title", "") if c.get("is_live") else ""}
                    for c in page.get("data", [])]
        return {"channels": channels, "cursor": page.get("pagination", {}).get("cursor", "")}

    def channel_status(self, channel):
        response = self.helix("streams", {"user_login": channel, "first": 1})
        if response.status_code != 200:
            raise HTTPException(502, "Cannot check this channel. Try again.")
        return {"channel": channel, "live": bool(response.json().get("data"))}

    @staticmethod
    def video_thumbnail(url):
        if not isinstance(url, str):
            return ""
        url = url.replace("%{width}", "640").replace("%{height}", "360").replace("{width}", "640").replace("{height}", "360")
        try:
            parsed = urlsplit(url)
            if (parsed.scheme == "https" and parsed.hostname == "static-cdn.jtvnw.net"
                    and parsed.port in (None, 443) and not parsed.username and not parsed.password
                    and not parsed.query and not parsed.fragment and not any(c.isspace() for c in url)):
                return url
        except ValueError:
            pass
        return ""

    @staticmethod
    def video_info(video):
        duration = video.get("duration", "")
        seconds = sum(int(n) * {"h": 3600, "m": 60, "s": 1}[unit]
                      for n, unit in re.findall(r"(\d+)([hms])", duration))
        return {"id": video["id"], "title": video.get("title", "Untitled VOD"),
                "channel": video.get("user_login", ""), "created_at": video.get("created_at", ""),
                "duration": duration, "duration_seconds": seconds,
                "thumbnail": Auth.video_thumbnail(video.get("thumbnail_url", ""))}

    def videos(self, channel, cursor=""):
        r = self.helix("users", {"login": channel})
        if r.status_code != 200:
            raise HTTPException(502, "Cannot look up the channel. Try again.")
        users = r.json().get("data", [])
        if not users:
            raise HTTPException(404, "Channel not found.")
        params = {"user_id": users[0]["id"], "type": "archive", "sort": "time", "first": 20}
        if cursor:
            params["after"] = cursor
        r = self.helix("videos", params)
        if r.status_code != 200:
            raise HTTPException(502, "Cannot load VODs. Try again.")
        result = r.json()
        return {"channel": channel, "videos": [self.video_info(v) for v in result.get("data", [])],
                "cursor": result.get("pagination", {}).get("cursor", "")}

    def video(self, video_id):
        r = self.helix("videos", {"id": video_id})
        if r.status_code == 404 or (r.status_code == 200 and not r.json().get("data")):
            raise HTTPException(404, "This VOD is no longer available. Refresh the VOD list.")
        if r.status_code != 200:
            raise HTTPException(502, "Cannot look up this VOD. Try again.")
        return self.video_info(r.json()["data"][0])

    def playback_identity(self):
        value = read_json(self.data / "playback.json")
        if not value:
            raise HTTPException(409, "Import playback login on the computer or NAS first. See README.")
        r = self.request("GET", f"{ID}/validate", headers={"Authorization": f"OAuth {value['token']}"})
        if r.status_code == 401:
            (self.data / "playback.json").unlink(missing_ok=True)
            raise HTTPException(401, "Playback login expired. Import it again on the computer or NAS.")
        if r.status_code != 200:
            raise HTTPException(502, "Cannot verify playback login. Try again.")
        identity = self.validate()
        if r.json().get("user_id") != identity["user_id"]:
            raise HTTPException(409, "Playback login belongs to another account. Import the signed-in account.")
        return value

    def logout(self):
        token = self.token
        self.clear_account()
        self.pending = None
        (self.data / "playback.json").unlink(missing_ok=True)
        revoked = False
        if token:
            try:
                r = self.request("POST", f"{ID}/revoke", data={"client_id": self.client_id, "token": token["access_token"]})
                revoked = r.status_code == 200
            except HTTPException:
                pass
        return {"state": "signed_out", "app_token_revoked": revoked,
                "message": "Local logins removed. This does not sign out the Twitch website."}
