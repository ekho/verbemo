#!/usr/bin/env python3
"""Reproduce the second UX69 pass in a NEW recordings directory."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: create-followup-fixtures.py NEW_RECORDINGS_DIRECTORY")
root = Path(sys.argv[1]).resolve()
if any(p.exists() for p in (root, root.parent / "before.json", root.parent / "empty-recordings")):
    raise SystemExit("Refusing existing follow-up data")
subprocess.run([sys.executable, str(Path(__file__).with_name("create-fixtures.py")), str(root)], check=True)
target = root / "2026-10-30_09-04-00-ux69"
shutil.copytree(root / "2026-10-29_09-00-00-ux69", target)


def write_json(name, value):
    (target / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


meta = json.loads((target / "meta.json").read_text(encoding="utf-8"))
meta["title"] = "UX69 Назначения — ошибка и неизвестный"
meta["started"] = "2026-10-30T09:04:00Z"
meta["calendar"]["title"] = meta["title"]
write_json("meta.json", meta)
transcript = json.loads((target / "transcript.json").read_text(encoding="utf-8"))
transcript["segments"] = transcript["segments"][:6]
transcript["segments"][-1]["speaker"] = "them ?"
write_json("transcript.json", transcript)
names = json.loads((target / "speakers.json").read_text(encoding="utf-8"))
names["speakers"]["them C"] = {"name": "Борис Примеров", "source": "manual", "participantID": "ux69-1"}
write_json("speakers.json", names)
# Keep the copied derived Markdown as in the observed run; UI reads transcript.json.
(root.parent / "empty-recordings").mkdir()
assert len(list(root.iterdir())) == 5
assert transcript["segments"][-1]["speaker"] == "them ?"
assert names["speakers"]["them C"]["participantID"] == "ux69-1"
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}
(root.parent / "before.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print("Created 5 synthetic meetings, wrong assignment, unknown speaker and empty library")
