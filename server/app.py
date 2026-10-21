import asyncio
import hmac
import re
import threading
from contextlib import asynccontextmanager, suppress
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from .auth import Auth, FOLLOW_SCOPE
from .player import Player
from .history import History
from .favorites import Favorites
from .quality import QualityPreference, QUALITY_PATTERN
from .recovery import Recovery
from .storage import DATA, read_json


def create_app(data=DATA, http=None, clock=None):
    settings = read_json(data / "settings.json") or {}
    auth = Auth(data, settings.get("client_id", ""), http=http, **({"clock": clock} if clock else {}))
    player = Player(data, **({"clock": clock} if clock else {}))
    history = History(data, **({"clock": clock} if clock else {}))
    favorites = Favorites(data)
    quality = QualityPreference(data)
    recovery = Recovery(**({"clock": clock} if clock else {}))
    def clear_account_playback():
        recovery.clear()
        player.stop()
    auth.on_clear = clear_account_playback
    lock = threading.RLock()

    def maintenance():
        with lock:
            try:
                if auth.token:
                    auth.validate()
                if player.job:
                    auth.playback_identity()
            except HTTPException:
                # Stop media when its account cannot be verified.
                player.stop()
            player.expire_idle()
            player.status()

    async def maintain():
        while True:
            await asyncio.to_thread(maintenance)
            await asyncio.sleep(60)

    @asynccontextmanager
    async def lifespan(app):
        player.stop()
        await asyncio.to_thread(maintenance)
        task = asyncio.create_task(maintain())
        yield
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        # Join any in-flight maintenance call before closing the shared client.
        with lock:
            player.stop()
            auth.http.close()

    app = FastAPI(title="Roku Twitch personal MVP", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.auth, app.state.player = auth, player
    app.state.history = history
    app.state.favorites = favorites
    app.state.quality = quality
    app.state.recovery = recovery

    def authorized(x_app_key: str = Header(default="")):
        key = settings.get("app_key", "")
        if not key or not hmac.compare_digest(x_app_key, key):
            raise HTTPException(401, "Pair this Roku with the server. Run setup first.")

    @app.middleware("http")
    async def no_cache(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.exception_handler(Exception)
    async def unexpected(request, exc):
        return JSONResponse(status_code=500, content={"detail": "Server error. Check local configuration and restart the server."})

    @app.get("/health")
    def health():
        return {"state": "ok"}

    @app.get("/api/account", dependencies=[Depends(authorized)])
    def account():
        with lock:
            if not auth.token:
                return {"signed_in": False, "playback_ready": False, "follows_ready": False}
            identity = auth.validate()
            playback_ready, message = False, ""
            try:
                auth.playback_identity()
                playback_ready = True
            except HTTPException as exc:
                message = exc.detail
            return {"signed_in": True, "login": identity["login"], "playback_ready": playback_ready,
                    "message": message, "ad_free": "unverified",
                    "follows_ready": FOLLOW_SCOPE in identity.get("scopes", [])}

    @app.post("/api/login", dependencies=[Depends(authorized)])
    def login():
        with lock:
            return auth.start()

    @app.post("/api/login/cancel", dependencies=[Depends(authorized)])
    def cancel():
        with lock:
            auth.pending = None
            return {"state": "cancelled"}

    @app.get("/api/login/{login_id}", dependencies=[Depends(authorized)])
    def poll(login_id: str):
        with lock:
            return auth.poll(login_id)

    @app.post("/api/logout", dependencies=[Depends(authorized)])
    def logout():
        with lock:
            player.stop()
            return auth.logout()

    def channel_name(channel):
        if not re.fullmatch(r"[a-zA-Z0-9_]{1,25}", channel):
            raise HTTPException(400, "Enter a Twitch channel name, without a URL.")
        return channel.lower()

    @app.get("/api/follows", dependencies=[Depends(authorized)])
    def follows(cursor: str = Query(default="", max_length=2048)):
        with lock:
            result = auth.follows(cursor)
            pinned = favorites.ids(auth.validate()["user_id"])
            for channel in result["channels"]:
                channel["pinned"] = channel["id"] in pinned
            return result

    class FavoriteUpdate(BaseModel):
        channel_id: str = Field(pattern=r"^[0-9]{1,20}$")
        pinned: bool = Field(strict=True)

    @app.post("/api/favorites", dependencies=[Depends(authorized)])
    def update_favorite(body: FavoriteUpdate):
        with lock:
            favorites.set_pinned(auth.validate()["user_id"], body.channel_id, body.pinned)
            return {"channel_id": body.channel_id, "pinned": body.pinned}

    @app.get("/api/search", dependencies=[Depends(authorized)])
    def search(q: str = Query(min_length=1, max_length=100), cursor: str = Query(default="", max_length=2048)):
        with lock:
            query = q.strip()
            if not query:
                raise HTTPException(400, "Enter a channel name to search.")
            return auth.search_channels(query, cursor)

    @app.get("/api/channel/{channel}", dependencies=[Depends(authorized)])
    def channel_status(channel: str):
        with lock:
            return auth.channel_status(channel_name(channel))

    @app.get("/api/subscription/{channel}", dependencies=[Depends(authorized)])
    def subscription(channel: str):
        with lock:
            return auth.subscription(channel_name(channel))

    class PlayRequest(BaseModel):
        channel: str = Field(min_length=1, max_length=25)

    @app.post("/api/play", dependencies=[Depends(authorized)])
    def play(body: PlayRequest):
        with lock:
            name = channel_name(body.channel)
            value = auth.playback_identity()
            user_id = auth.validate()["user_id"]
            recovery.clear()
            result = player.start(name, value["token"], quality.get(user_id))
            recovery.begin(user_id, "live", name)
            return recovery.attach(player, result)

    @app.get("/api/player", dependencies=[Depends(authorized)])
    def state():
        with lock:
            return player.status()

    @app.get("/api/videos/{channel}", dependencies=[Depends(authorized)])
    def videos(channel: str, cursor: str = Query(default="", max_length=2048)):
        with lock:
            result = auth.videos(channel_name(channel), cursor)
            entries = history.entries(auth.validate()["user_id"])
            for video in result["videos"]:
                video["position"] = min(max(0, entries.get(video["id"], {}).get("position", 0)), video["duration_seconds"])
            return result

    class VodRequest(BaseModel):
        video_id: str = Field(pattern=r"^[0-9]{1,20}$")
        resume: bool = False

    @app.post("/api/vod/play", dependencies=[Depends(authorized)])
    def play_vod(body: VodRequest):
        with lock:
            value = auth.playback_identity()
            try:
                video = auth.video(body.video_id)
            except HTTPException as exc:
                if exc.status_code == 404:
                    raise HTTPException(404, {"code": "vod_unavailable", "message": "This recording is no longer available."}) from None
                raise
            user_id = auth.validate()["user_id"]
            video["play_start"] = min(history.position(user_id, video["id"]), max(0, video["duration_seconds"] - 2)) if body.resume else 0
            recovery.clear()
            result = player.start_vod(video, value["token"], quality.get(user_id))
            recovery.begin(user_id, "vod", video["id"])
            return recovery.attach(player, result)

    class RecoverRequest(BaseModel):
        recovery_id: str = Field(pattern=r"^[a-f0-9]{32}$")
        attempt: int = Field(ge=1, le=1000000)
        position: float | None = Field(default=None, ge=0, le=100000000, allow_inf_nan=False)

    @app.post("/api/player/recover", dependencies=[Depends(authorized)])
    def recover_playback(body: RecoverRequest):
        with lock:
            user_id = auth.validate()["user_id"]
            session = recovery.check(body.recovery_id, user_id)
            if body.attempt < session["attempt"]:
                raise HTTPException(409, "A newer recovery attempt already started.")
            if body.attempt == session["attempt"]:
                if player.job and player.job.get("recovery_id") == body.recovery_id:
                    return recovery.attach(player, player.status())
                raise HTTPException(409, "This recovery attempt ended. Open the video again.")
            value = auth.playback_identity()
            if session["kind"] == "vod":
                video = auth.video(session["target"])
                position = body.position if body.position is not None else history.position(user_id, video["id"])
                video["play_start"] = min(position, max(0, video["duration_seconds"] - 2))
                history.save(user_id, {**video, "kind": "vod", "video_id": video["id"]}, position)
                session["attempt"] = body.attempt
                result = player.start_vod(video, value["token"], quality.get(user_id))
            else:
                if not auth.channel_status(session["target"])["live"]:
                    raise HTTPException(410, "This channel is offline. Return to its recordings.")
                session["attempt"] = body.attempt
                result = player.start(session["target"], value["token"], quality.get(user_id))
            session["touched"] = recovery.clock()
            return recovery.attach(player, result)

    @app.get("/api/history", dependencies=[Depends(authorized)])
    def recent_videos():
        with lock:
            return {"videos": history.recent(auth.validate()["user_id"])}

    class HistoryUpdate(BaseModel):
        video_id: str = Field(pattern=r"^[0-9]{1,20}$")
        operation: Literal["remove", "watched"]

    @app.post("/api/history/update", dependencies=[Depends(authorized)])
    def update_history(body: HistoryUpdate):
        with lock:
            user_id = auth.validate()["user_id"]
            # A playing recording would be added again by its next heartbeat.
            if (player.job and player.job.get("kind") == "vod"
                    and player.job.get("owner_user_id") == user_id
                    and player.job.get("video_id") == body.video_id):
                raise HTTPException(409, "Stop this recording before changing its saved progress.")
            history.remove(user_id, body.video_id)
            return {"state": "removed" if body.operation == "remove" else "watched", "video_id": body.video_id}

    @app.get("/api/vod/progress/{video_id}", dependencies=[Depends(authorized)])
    def video_progress(video_id: str):
        with lock:
            if not re.fullmatch(r"[0-9]{1,20}", video_id):
                raise HTTPException(400, "Invalid video ID.")
            return {"video_id": video_id, "position": history.position(auth.validate()["user_id"], video_id)}

    def save_progress(position, finished=False):
        job = player.job
        if not job or job.get("kind") != "vod" or (position is None and not finished):
            return
        user_id = auth.validate()["user_id"]
        if job.get("owner_user_id") != user_id:
            raise HTTPException(409, "This playback session belongs to another account.")
        history.save(user_id, job, position, finished)

    def owned_job(job_id):
        user_id = auth.validate()["user_id"]
        if not player.job or player.job["id"] != job_id or player.job.get("owner_user_id") != user_id:
            raise HTTPException(409, "Playback session changed. Open the video again.")
        if player.job.get("state") != "ready":
            raise HTTPException(409, "Wait for playback to start before changing quality.")
        return user_id

    @app.get("/api/player/qualities", dependencies=[Depends(authorized)])
    def qualities(job_id: str = Query(min_length=1, max_length=64)):
        with lock:
            owned_job(job_id)
            return player.qualities()

    class QualityUpdate(BaseModel):
        job_id: str = Field(min_length=1, max_length=64)
        quality: str = Field(pattern=QUALITY_PATTERN)
        position: float | None = Field(default=None, ge=0, le=100000000, allow_inf_nan=False)

    @app.post("/api/player/quality", dependencies=[Depends(authorized)])
    def update_quality(body: QualityUpdate):
        with lock:
            user_id = owned_job(body.job_id)
            choices = player.qualities()
            if choices["state"] != "ready" or body.quality not in choices["qualities"]:
                raise HTTPException(409, "This quality is unavailable. Open the quality menu again.")
            if player.job["kind"] == "vod" and body.position is None:
                raise HTTPException(400, "Wait for the playback position before changing quality.")
            value = auth.playback_identity()
            save_progress(body.position)
            result = player.change_quality(body.quality, value["token"], body.position)
            if player.job:
                player.job["owner_user_id"] = user_id
            quality.save(user_id, body.quality)
            return recovery.attach(player, result)

    class HeartbeatRequest(BaseModel):
        job_id: str = Field(min_length=1, max_length=64)
        position: float | None = Field(default=None, ge=0, le=100000000, allow_inf_nan=False)

    @app.post("/api/player/heartbeat", dependencies=[Depends(authorized)])
    def heartbeat(body: HeartbeatRequest):
        with lock:
            if not player.job or player.job["id"] != body.job_id:
                raise HTTPException(409, "Playback session ended. Select the video again.")
            player.last_read = player.clock()
            recovery.touch(player.job)
            save_progress(body.position)
            result = player.status()
            return {"state": result["state"], "message": result.get("message", "")}

    class StopRequest(BaseModel):
        job_id: str = Field(default="", max_length=64)
        recovery_id: str = Field(default="", max_length=32)
        position: float | None = Field(default=None, ge=0, le=100000000, allow_inf_nan=False)
        finished: bool = False

    @app.post("/api/stop", dependencies=[Depends(authorized)])
    def stop(body: StopRequest = StopRequest()):
        with lock:
            if body.recovery_id:
                recovery.check(body.recovery_id, auth.validate()["user_id"])
            elif body.job_id and (not player.job or player.job["id"] != body.job_id):
                raise HTTPException(409, "Playback session already ended.")
            if (body.position is not None or body.finished) and not body.job_id:
                raise HTTPException(400, "A playback session is required to save progress.")
            try:
                save_progress(body.position, body.finished)
            finally:
                recovery.clear()
                player.stop()
            return {"state": "idle"}

    @app.get("/media/{job_id}/{name}", dependencies=[Depends(authorized)])
    def media(job_id: str, name: str):
        with lock:
            if not player.job or job_id != player.job["id"] or not re.fullmatch(r"(?:index\.m3u8|segment\d{6,}\.ts)", name):
                raise HTTPException(404, "Media not found.")
            path = player.root / job_id / name
            if not path.is_file():
                raise HTTPException(404, "Media not ready.")
            player.last_read = player.clock()
            return FileResponse(path, media_type="application/vnd.apple.mpegurl" if name.endswith("m3u8") else "video/mp2t")

    return app


app = create_app()
