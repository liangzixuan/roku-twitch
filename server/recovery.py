import secrets
import time

from fastapi import HTTPException


class Recovery:
    # One logical playback session. Replaced by a new selection or explicit stop.
    def __init__(self, clock=time.time):
        self.clock = clock
        self.session = None

    def clear(self):
        self.session = None

    def begin(self, user_id, kind, target):
        self.session = {"id": secrets.token_hex(16), "user_id": user_id,
                        "kind": kind, "target": target, "attempt": 0, "touched": self.clock()}

    def attach(self, player, result):
        if self.session:
            result["recovery_id"] = self.session["id"]
            if player.job:
                player.job["recovery_id"] = self.session["id"]
                player.job["owner_user_id"] = self.session["user_id"]
        return result

    def check(self, recovery_id, user_id):
        session = self.session
        if not session or session["id"] != recovery_id or self.clock() - session["touched"] > 600:
            raise HTTPException(409, "Playback session ended. Open the video again.")
        if session["user_id"] != user_id:
            raise HTTPException(403, "Playback belongs to another account. Open the video again.")
        return session

    def touch(self, job):
        if self.session and job and job.get("recovery_id") == self.session["id"]:
            self.session["touched"] = self.clock()
