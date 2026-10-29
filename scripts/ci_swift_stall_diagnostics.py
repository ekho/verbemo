"""Temporary CI tee: sample only our Swift test helper after silent progress stalls."""
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

STALL_SECONDS = 180


def owned_descendants(root_pid, listing):
    processes = {}
    for line in listing.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, parent, group, command = fields
            processes[int(pid)] = (int(parent), int(group), Path(command).name)
    descendants = []
    for pid, (parent, group, command) in processes.items():
        ancestor, seen = pid, set()
        while ancestor in processes and ancestor not in seen and ancestor != root_pid:
            seen.add(ancestor)
            ancestor = processes[ancestor][0]
        if ancestor == root_pid:
            descendants.append((pid, parent, group, command))
    return sorted(descendants)


def owned_test_pids(root_pid, listing):
    return [pid for pid, _, _, command in owned_descendants(root_pid, listing)
            if command in {"swiftpm-testing", "swiftpm-testing-helper", "verbemoTests"}]


def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()


def main():
    log_path = Path(sys.argv[1])
    process = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    finished = threading.Event()
    last_output = time.monotonic()

    def monitor():
        sampled_progress, reported_missing_progress, last_attempt, sequence = None, None, 0, 0
        while not finished.wait(1):
            progress, now = last_output, time.monotonic()
            if now - progress < STALL_SECONDS or progress == sampled_progress or now - last_attempt < 30:
                continue
            last_attempt = now
            try:
                listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="],
                                         check=True, capture_output=True, text=True, timeout=5).stdout
                targets = owned_test_pids(process.pid, listing)
                if process.poll() is not None or finished.is_set() or progress != last_output:
                    continue
                if not targets:
                    if reported_missing_progress != progress:
                        reported_missing_progress = progress
                        emit(f"\nSwift stall: no matching helper for owned launch pid={process.pid}; owned process metadata (max 16):\n")
                        for pid, parent, group, command in owned_descendants(process.pid, listing)[:16]:
                            emit(f"pid={pid} ppid={parent} pgid={group} basename={command}\n")
                    continue
                sampled_progress = progress
                sequence += 1
                for pid in targets:
                    # Recheck ownership immediately before sampling; never sample by name alone.
                    current = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="],
                                             check=True, capture_output=True, text=True, timeout=5).stdout
                    if pid not in owned_test_pids(process.pid, current):
                        continue
                    sample_path = log_path.with_name(f"swift-stall-{sequence}-{pid}.txt")
                    emit(f"\n::group::Owned Swift test stall sample pid={pid}\n")
                    result = subprocess.run(["/usr/bin/sample", str(pid), "3", "-file", str(sample_path)],
                                            capture_output=True, text=True, timeout=15)
                    emit(f"sample exit={result.returncode}\n" + result.stdout + result.stderr)
                    if sample_path.exists():
                        emit(sample_path.read_text(errors="replace"))
                    emit("\n::endgroup::\n")
            except Exception as error:
                emit(f"\nSwift stall diagnostic unavailable: {type(error).__name__}\n")

    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    try:
        with log_path.open("wb") as log:
            while data := os.read(process.stdout.fileno(), 65536):
                last_output = time.monotonic()
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
        return process.wait()
    finally:
        finished.set()
        watcher.join(timeout=20)


if __name__ == "__main__":
    raise SystemExit(main())
