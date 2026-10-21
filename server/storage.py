import json
import os
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get("ROKU_TWITCH_DATA", str(ROOT / "data")))


def private_write(path: Path, text: str):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def write_json(path: Path, value):
    private_write(path, json.dumps(value, ensure_ascii=False))
