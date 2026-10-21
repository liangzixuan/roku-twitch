import time

from .storage import read_json, write_json


class History:
    # Calls run under the app state lock. Store metadata, never playback URLs.
    def __init__(self, data, clock=time.time):
        self.path = data / "history.json"
        self.clock = clock

    def entries(self, user_id):
        return (read_json(self.path) or {}).get(user_id, {})

    def position(self, user_id, video_id):
        return self.entries(user_id).get(video_id, {}).get("position", 0)

    def recent(self, user_id):
        return sorted(self.entries(user_id).values(), key=lambda entry: entry["updated_at"], reverse=True)

    def remove(self, user_id, video_id):
        all_users = read_json(self.path) or {}
        entries = all_users.get(user_id, {})
        if video_id in entries:
            del entries[video_id]
            write_json(self.path, all_users)

    def save(self, user_id, job, position=None, finished=False):
        if job.get("kind") != "vod" or (position is None and not finished):
            return
        all_users = read_json(self.path) or {}
        entries = all_users.setdefault(user_id, {})
        duration = job["duration_seconds"]
        position = max(0, min(int(position or 0), duration))
        video_id = job["video_id"]
        if finished or position == 0 or (duration > 0 and position >= duration - 10):
            entries.pop(video_id, None)
        else:
            entries[video_id] = {"id": video_id, "channel": job["channel"], "title": job["title"],
                                 "duration_seconds": duration, "position": position, "updated_at": self.clock()}
            entries[video_id]["thumbnail"] = job.get("thumbnail", "")
            entries[video_id]["created_at"] = job.get("created_at", "")
        all_users[user_id] = dict(sorted(entries.items(), key=lambda item: item[1]["updated_at"], reverse=True)[:100])
        write_json(self.path, all_users)
