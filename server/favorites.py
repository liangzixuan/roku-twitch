from .storage import read_json, write_json


class Favorites:
    # Calls run under the app state lock. Channel IDs survive name changes.
    def __init__(self, data):
        self.path = data / "favorites.json"

    def ids(self, user_id):
        return set((read_json(self.path) or {}).get(user_id, []))

    def set_pinned(self, user_id, channel_id, pinned):
        accounts = read_json(self.path) or {}
        entries = set(accounts.get(user_id, []))
        if pinned:
            entries.add(channel_id)
        else:
            entries.discard(channel_id)
        accounts[user_id] = sorted(entries)
        write_json(self.path, accounts)
