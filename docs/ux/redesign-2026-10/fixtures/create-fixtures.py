#!/usr/bin/env python3
"""Create synthetic UX69 recordings in a new directory; never copy user data."""
import hashlib
import json
from pathlib import Path
import sys
import wave

if len(sys.argv) != 2:
    raise SystemExit("Usage: create-fixtures.py NEW_RECORDINGS_DIRECTORY")
root = Path(sys.argv[1]).resolve()
if root.exists():
    raise SystemExit(f"Refusing existing destination: {root}")
manifest_path = root.parent / "fixture-manifest.json"
if manifest_path.exists():
    raise SystemExit(f"Refusing existing manifest: {manifest_path}")
root.mkdir(parents=True)
names = ["Анна Тестовая", "Борис Примеров", "Вера Макетная", "Глеб Учебный",
         "Дарья Демонстрационная", "Егор Образцов", "Жанна Проверочная",
         "Зоя Синтетическая", "Илья Условный"]
stamp = "2026-10-29T09:00:00Z"


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


for index, (title, count, people, state) in enumerate([
    ("UX69 Атлас — планирование", 18, 3, "ready"),
    ("UX69 Атлас — длинная встреча", 180, 9, "ready"),
    ("UX69 Импорт — ошибка обработки", 0, 0, "failed"),
    ("UX69 Импорт — отложенная обработка", 0, 0, "deferred"),
]):
    folder = root / f"2026-10-29_09-{index:02d}-00-ux69"
    folder.mkdir()
    duration = max(60, count * 10)
    with wave.open(str(folder / "audio.wav"), "wb") as audio:
        audio.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
        for _ in range(duration):
            audio.writeframesraw(bytes(16000))
    participants = [{"id": f"ux69-{i}", "name": names[i],
                     "email": f"ux69-{i}@example.invalid"} for i in range(people)]
    meta = {"title": title, "started": f"2026-10-29T09:{index:02d}:00Z",
            "duration_seconds": duration, "files": {"mixed": "audio.wav"},
            "speakers_status": "failed", "summary_status": "failed"}
    if people:
        meta["calendar"] = {"event_id": f"synthetic-ux69-{index}",
                            "association": "confirmed", "title": title,
                            "calendar_title": "Синтетические данные UX69",
                            "participants": participants}
    if state == "failed":
        meta["transcription_failed"] = "Synthetic UX69: model unavailable"
    if state == "deferred":
        meta["transcription_deferred"] = True
    write_json(folder / "meta.json", meta)
    if not count:
        continue
    segments = [{"speaker": f"them {chr(65 + i % people)}",
                 "start_ms": i * 10000, "end_ms": (i + 1) * 10000,
                 "text": f"Реплика {i + 1}. Обсуждаем подготовку учебного проекта. "
                         + ("Кварцевый компас нужен для проверки поиска по тексту. " if i == 1 else "")
                         + ("Нужно согласовать сроки, проверить материалы и записать решение. " * (4 if i % 7 == 0 else 1))}
                for i in range(count)]
    transcript = {"engine": "whisper", "model": "synthetic-ux69",
                  "created_at": stamp, "segments": segments}
    write_json(folder / "transcript.json", transcript)
    (folder / "transcript.md").write_text("# " + title + "\n\n" + "\n\n".join(
        f"**[{s['start_ms'] // 1000}s] {s['speaker']}:** {s['text']}" for s in segments), encoding="utf-8")
    write_json(folder / "speakers.json", {"created_at": stamp, "speakers": {
        f"them {chr(65 + i)}": {"name": names[i], "source": "manual", "participantID": f"ux69-{i}"}
        for i in range(max(1, people - 1))}})
    (folder / "summary.md").write_text("# Решения учебной встречи\n\n- Сапфировый маяк — уникальная фраза только в сводке.\n- Анна готовит материалы.\n- Борис проверяет сроки.\n", encoding="utf-8")
    if index == 0:
        archive = folder / "transcripts" / "synthetic-previous"
        archive.mkdir(parents=True)
        older = dict(transcript, engine="parakeet", created_at="2026-10-28T09:00:00Z", segments=segments[:6])
        write_json(archive / "transcript.json", older)
        (archive / "transcript.md").write_text("# Предыдущая синтетическая версия\n", encoding="utf-8")
        write_json(archive / "meta.json", {"speakers_status": "failed", "summary_status": "failed"})
    assert len(json.loads((folder / "transcript.json").read_text(encoding="utf-8"))["segments"]) == count
    with wave.open(str(folder / "audio.wav")) as audio:
        assert audio.getnframes() == duration * 8000

assert len(list(root.iterdir())) == 4
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}
write_json(manifest_path, manifest)
print(f"Created 4 synthetic meetings, 198 current segments, 1 archive: {root}")
