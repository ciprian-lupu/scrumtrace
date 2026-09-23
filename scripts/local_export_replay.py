#!/usr/bin/env python3
"""Guarded local replay for existing ScrumTrace sessions. Never uploads or edits sources."""

from __future__ import annotations

import argparse
import hashlib
import html.parser
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.parse
import zipfile
from pathlib import Path, PurePosixPath


REPO_ROOT = Path(__file__).resolve().parents[1]
RUN_PREFIX = "/private/tmp/scrumtrace-local-export-review-"
DEFAULT_ALIASES = ("short-ro", "long-ro", "sub15", "no-window")
ACTIVE_STATUSES = {"recording", "paused", "transcribing", "slicing", "evaluating", "synthesizing"}
REPLAY_TEST = "ScrumTraceTests/LocalExportReplayTests/testExistingSessionCopiesReplayLocallyAndRepeatIdentically"
MAX_PACK_BYTES = 35 * 1024 * 1024


class ReplayError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ReplayError(message)


def inside(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def no_link_components(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            fail("A required private source path is missing.")
        if stat.S_ISLNK(mode):
            fail("A private source path contains a symbolic link.")


def tree_inventory(root: Path) -> dict[str, dict[str, int | str]]:
    if not root.is_dir() or root.is_symlink():
        fail("A session source is not a real directory.")
    files: dict[str, dict[str, int | str]] = {}
    for base, directories, names in os.walk(root, followlinks=False):
        base_path = Path(base)
        for name in list(directories):
            path = base_path / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                fail("A private source tree contains a link or non-directory entry.")
        for name in names:
            path = base_path / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                fail("A private source tree contains a link or non-regular file.")
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            rel = path.relative_to(root).as_posix()
            files[rel] = {"sha256": digest.hexdigest(), "bytes": info.st_size, "mtime_ns": info.st_mtime_ns}
    return files


def aggregate_bytes(items: dict[str, dict[str, int | str]]) -> int:
    return sum(int(row["bytes"]) for row in items.values())


def content_inventory(items: dict[str, dict[str, int | str]]) -> dict[str, tuple[int, str]]:
    return {path: (int(row["bytes"]), str(row["sha256"])) for path, row in items.items()}


def copy_tree_safe(source: Path, destination: Path) -> None:
    def copy_regular(src: str, dst: str) -> str:
        src_path = Path(src)
        info = src_path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            fail("A source changed to a link or non-regular file during the snapshot.")
        return shutil.copy2(src, dst, follow_symlinks=False)

    shutil.copytree(source, destination, symlinks=False, copy_function=copy_regular)


def make_owner_writable(root: Path) -> None:
    for base, directories, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        os.chmod(base_path, stat.S_IMODE(base_path.stat().st_mode) | stat.S_IWUSR | stat.S_IXUSR)
        for name in directories:
            path = base_path / name
            if path.is_symlink():
                fail("A copied session contains a symbolic link.")
            os.chmod(path, stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR | stat.S_IXUSR)
        for name in files:
            path = base_path / name
            if path.is_symlink() or not path.is_file():
                fail("A copied session contains a symbolic link or non-regular file.")
            os.chmod(path, stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)


def make_read_only(root: Path) -> None:
    for base, directories, files in os.walk(root, topdown=False, followlinks=False):
        base_path = Path(base)
        for name in files:
            path = base_path / name
            if path.is_symlink():
                fail("The source snapshot contains a symbolic link.")
            os.chmod(path, stat.S_IMODE(path.stat().st_mode) & ~0o222)
        for name in directories:
            path = base_path / name
            if path.is_symlink():
                fail("The source snapshot contains a symbolic link.")
            os.chmod(path, (stat.S_IMODE(path.stat().st_mode) & ~0o222) | stat.S_IXUSR)
        os.chmod(base_path, (stat.S_IMODE(base_path.stat().st_mode) & ~0o222) | stat.S_IXUSR)


def check_recording_lock(lock_path: Path) -> None:
    try:
        lock_info = lock_path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(lock_info.st_mode) or not stat.S_ISREG(lock_info.st_mode):
        fail("The recording lock is not a regular file; private replay stopped.")
    try:
        lines = lock_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        fail("The recording lock could not be read; private replay stopped.")
    if len(lines) < 2 or not lines[1].strip().isdigit() or int(lines[1].strip()) <= 0:
        fail("The recording lock is ambiguous; private replay stopped.")
    pid = int(lines[1].strip())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    except PermissionError:
        pass
    except OSError:
        return
    result = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], text=True, capture_output=True, check=False)
    executable = Path(result.stdout.strip()).name if result.returncode == 0 and result.stdout.strip() else ""
    if executable == "ScrumTrace":
        fail("A live ScrumTrace recording lock exists; private replay stopped.")
    if not executable:
        fail("The recording lock owner could not be identified; private replay stopped.")
    # AgentLog considers a lock stale when its PID is no longer ScrumTrace.


def check_processor_events(log_path: Path, session_ids: set[str]) -> None:
    try:
        info = log_path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail("The current processing log is not a regular file; private replay stopped.")
    active: set[str] = set()
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        fail("The current processing log could not be read; private replay stopped.")
    for line in lines:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        sid = row.get("session")
        if sid not in session_ids:
            continue
        event = row.get("event")
        if event == "processor_begin":
            active.add(sid)
        elif event in {"processor_ok", "processor_fail"}:
            active.discard(sid)
    if active:
        fail("A selected source has an unfinished processing event; private replay stopped.")


class LocalLinks(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.targets: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if name in {"href", "src"} and value:
                self.targets.append(value)


def check_link(export: Path, target: str) -> None:
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme or target.startswith("#"):
        return
    decoded = urllib.parse.unquote(parsed.path)
    posix = PurePosixPath(decoded)
    if posix.is_absolute() or ".." in posix.parts:
        fail("An export document contains an absolute or escaping local link.")
    if not (export / Path(*posix.parts)).is_file():
        fail("An export document links to a missing local asset.")


def validate_export(session: Path) -> dict[str, int]:
    export = session / "export"
    if not export.is_dir() or export.is_symlink():
        fail("A replay export folder is missing or unsafe.")
    for required in ("AGENT_CONTEXT.md", "AGENT_PROMPT.txt", "SESSION_BRIEF.html", "session.manifest.json", "session-pack.zip"):
        if not (export / required).is_file():
            fail("A replay export is missing a required local handoff file.")
    if (export / "full_transcript.json").exists():
        fail("The replay unexpectedly included the opted-out full transcript.")

    for document in ("SESSION_BRIEF.html",):
        parser = LocalLinks()
        parser.feed((export / document).read_text(encoding="utf-8"))
        for target in parser.targets:
            check_link(export, target)
    markdown_link = re.compile(r"!?\[[^\]]*\]\((?:<([^>]+)>|([^\s)]+))")
    for document in ("AGENT_CONTEXT.md", "AGENT_PROMPT.txt"):
        content = (export / document).read_text(encoding="utf-8")
        for match in markdown_link.finditer(content):
            check_link(export, match.group(1) or match.group(2))

    zip_path = export / "session-pack.zip"
    folder_files: dict[str, str] = {}
    for base, directories, files in os.walk(export, followlinks=False):
        base_path = Path(base)
        for name in directories:
            if (base_path / name).is_symlink():
                fail("The export contains a symbolic link.")
        for name in files:
            path = base_path / name
            if path.is_symlink() or not path.is_file():
                fail("The export contains a non-regular member.")
            if path == zip_path:
                continue
            relative = path.relative_to(export).as_posix()
            folder_files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    try:
        with zipfile.ZipFile(zip_path) as archive:
            members: dict[str, str] = {}
            for info in archive.infolist():
                if info.is_dir():
                    continue
                member = PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if member.is_absolute() or ".." in member.parts or stat.S_ISLNK(mode):
                    fail("The session ZIP contains an unsafe member.")
                members[info.filename] = hashlib.sha256(archive.read(info)).hexdigest()
    except (OSError, zipfile.BadZipFile):
        fail("The session ZIP could not be read.")
    if members != folder_files:
        fail("The session ZIP does not match the export folder's files and contents.")
    zip_bytes = zip_path.stat().st_size
    folder_bytes = sum((export / path).stat().st_size for path in folder_files)
    if zip_bytes <= 0 or zip_bytes > MAX_PACK_BYTES or folder_bytes > MAX_PACK_BYTES:
        fail("The replay ZIP or export folder exceeds the 35 MB contract.")
    return {"zip_bytes": zip_bytes, "export_folder_bytes": folder_bytes, "export_files": len(folder_files)}


def inspect_fixture(
    row: dict[str, object],
    source_root: Path,
) -> tuple[str, Path, dict[str, dict[str, int | str]], int]:
    alias = str(row.get("alias", ""))
    source_value = row.get("source_path")
    if not alias or not isinstance(source_value, str):
        fail("The inventory entry is incomplete.")
    source = Path(source_value).absolute()
    no_link_components(source)
    resolved_source = source.resolve(strict=True)
    if not inside(resolved_source, source_root):
        fail("An inventory source is outside the selected source root.")
    manifest_path = source / "session.manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("A source manifest is unreadable.")
    session_id = manifest.get("session_id")
    if not isinstance(session_id, str) or session_id != source.name:
        fail("A source folder does not match its manifest identity.")
    if manifest.get("pipeline_status") != "completed" or "transcribing" not in manifest.get("completed_stages", []):
        fail("A selected source has incomplete processing; private replay stopped.")
    source_files = tree_inventory(source)
    movie = source / "archive" / "session.mp4"
    movie_bytes = movie.stat().st_size if movie.is_file() else 0
    return alias, source, source_files, movie_bytes


def prepare_fixture(
    alias: str,
    source: Path,
    source_files: dict[str, dict[str, int | str]],
    output_root: Path,
) -> tuple[str, Path, dict[str, dict[str, int | str]]]:
    session_id = source.name
    snapshot = output_root / "snapshot" / session_id
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    copy_tree_safe(source, snapshot)
    snapshot_files = tree_inventory(snapshot)
    source_after_copy = tree_inventory(source)
    if content_inventory(source_files) != content_inventory(snapshot_files) or source_files != source_after_copy:
        fail("A source changed during its private snapshot; that fixture was not accepted.")
    snapshot_manifest = json.loads((snapshot / "session.manifest.json").read_text(encoding="utf-8"))
    if snapshot_manifest.get("session_id") != session_id:
        fail("A private snapshot failed its identity check.")
    make_read_only(snapshot)

    for arm in ("baseline", "replay"):
        destination = output_root / arm / "sessions" / session_id
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy_tree_safe(snapshot, destination)
        make_owner_writable(destination)
        (destination / ".scrumtrace-replay-copy").write_text("private independent copy\n", encoding="utf-8")
        (destination / ".fixture-alias").write_text(alias, encoding="utf-8")
        if arm == "baseline":
            os.chmod(destination / ".scrumtrace-replay-copy", 0o400)
            os.chmod(destination / ".fixture-alias", 0o400)
            make_read_only(destination)
        else:
            os.chmod(destination / ".scrumtrace-replay-copy", 0o600)
            os.chmod(destination / ".fixture-alias", 0o600)
    for private_path in (
        output_root / "snapshot",
        output_root / "baseline",
        output_root / "baseline" / "sessions",
        output_root / "replay",
        output_root / "replay" / "sessions",
    ):
        os.chmod(private_path, 0o700)
    return alias, source, source_files


def require_replay_xctest_passed(result_bundle: Path) -> None:
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail("Xcode did not provide readable replay test results; no private replay pass is recorded.")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError:
        fail("Xcode replay test results were not valid JSON; no private replay pass is recorded.")
    target_name = "testExistingSessionCopiesReplayLocallyAndRepeatIdentically()"
    matches: list[dict[str, object]] = []
    pending: list[object] = [document]
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case" and node.get("name") == target_name:
                matches.append(node)
            pending.extend(node.values())
        elif isinstance(node, list):
            pending.extend(node)
    if len(matches) != 1 or matches[0].get("result") != "Passed":
        fail("The guarded replay XCTest did not pass exactly once; skipped tests are not accepted.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path, help="Private local inventory JSON")
    parser.add_argument("--source-root", required=True, type=Path, help="Existing local ScrumTrace sessions directory")
    parser.add_argument("--output-root", required=True, type=Path, help="New /private/tmp/scrumtrace-local-export-review-* root")
    parser.add_argument("--derived-data", required=True, type=Path, help="Isolated Xcode DerivedData outside the repository")
    parser.add_argument("--aliases", default=",".join(DEFAULT_ALIASES), help="Comma-separated inventory aliases")
    parser.add_argument("--recording-lock", type=Path, help="Optional override for the AgentLog recording lock")
    args = parser.parse_args()

    inventory_path = args.inventory.absolute()
    source_root = args.source_root.absolute()
    output_root = args.output_root.resolve(strict=False)
    derived_data = args.derived_data.resolve(strict=False)
    repo = REPO_ROOT.resolve()
    vault = (Path.home() / "Movies" / "ScrumTrace" / "sessions").resolve()
    private_tmp = Path("/private/tmp").resolve(strict=True)
    if not inventory_path.is_file() or inventory_path.is_symlink():
        fail("The private metadata inventory is missing or unsafe.")
    no_link_components(source_root)
    no_link_components(inventory_path)
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir() or inside(source_root, repo) or inside(repo, source_root):
        fail("The private source root overlaps the repository or is not a directory.")
    try:
        output_root.lstat()
    except FileNotFoundError:
        pass
    else:
        fail("The private output root already exists; choose a new unique path.")
    if output_root.parent != private_tmp or not str(output_root).startswith(RUN_PREFIX) or inside(output_root, repo) or inside(repo, output_root):
        fail("The private output root must be a new guarded /private/tmp review directory.")
    if inside(output_root, vault) or inside(vault, output_root) or inside(output_root, source_root) or inside(source_root, output_root):
        fail("The private output root overlaps the source or real recording vault.")
    if inside(derived_data, repo) or inside(repo, derived_data):
        fail("DerivedData must stay outside the repository.")

    lock = args.recording_lock.absolute() if args.recording_lock else Path.home() / "Library" / "Logs" / "ScrumTrace" / "recording.lock"
    check_recording_lock(lock)
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("The private metadata inventory is unreadable.")
    rows = inventory.get("fixtures") if isinstance(inventory, dict) else None
    if not isinstance(rows, list):
        fail("The private inventory has no fixture list.")
    requested = [item.strip() for item in args.aliases.split(",") if item.strip()]
    if len(requested) < 2 or len(requested) != len(set(requested)):
        fail("Choose at least two distinct fixture aliases.")
    by_alias = {str(row.get("alias")): row for row in rows if isinstance(row, dict)}
    if any(alias not in by_alias for alias in requested):
        fail("A requested fixture alias is not in the private inventory.")

    inspected: list[tuple[str, Path, dict[str, dict[str, int | str]], int]] = []
    required_bytes = 512 * 1024 * 1024
    for alias in requested:
        fixture = inspect_fixture(by_alias[alias], source_root)
        inspected.append(fixture)
        fixture_alias, source, source_files, movie_bytes = fixture
        check_processor_events(Path.home() / "Library" / "Logs" / "ScrumTrace" / "agent.jsonl", {source.name})
        required_bytes += aggregate_bytes(source_files) * 3 + movie_bytes
    # Give an uncached isolated Xcode build up to 2 GiB and preserve at least
    # 512 MiB for encoders, logs, result bundles and APFS metadata.
    required_bytes += 512 * 1024 * 1024 if derived_data.exists() else 2 * 1024 * 1024 * 1024
    if shutil.disk_usage(private_tmp).free < required_bytes:
        fail("There is not enough private disk space for all independent copies, media work and Xcode output.")

    output_root.mkdir(parents=True, mode=0o700)
    os.chmod(output_root, 0o700)
    marker = output_root / ".scrumtrace-local-export-review"
    marker.write_text("owner-only private local replay\n", encoding="utf-8")
    os.chmod(marker, 0o600)
    replay_sessions = output_root / "replay" / "sessions"
    replay_sessions.mkdir(parents=True, mode=0o700)
    (replay_sessions / ".scrumtrace-replay-sessions").write_text("private replay copies\n", encoding="utf-8")
    os.chmod(replay_sessions / ".scrumtrace-replay-sessions", 0o600)

    selected: dict[str, tuple[Path, dict[str, dict[str, int | str]]]] = {}
    private_hashes: dict[str, object] = {}
    for fixture_alias, source, source_files, _movie_bytes in inspected:
        fixture_alias, source, source_files = prepare_fixture(fixture_alias, source, source_files, output_root)
        selected[fixture_alias] = (source, source_files)
        private_hashes[fixture_alias] = {"files": source_files}
    os.chmod(replay_sessions / ".scrumtrace-replay-sessions", 0o600)
    private_dir = output_root / ".private"
    private_dir.mkdir(mode=0o700)
    (private_dir / "source-hashes.json").write_text(json.dumps(private_hashes, sort_keys=True), encoding="utf-8")
    os.chmod(private_dir / "source-hashes.json", 0o600)

    # Check again immediately before processing, after every independent copy exists.
    check_recording_lock(lock)
    check_processor_events(Path.home() / "Library" / "Logs" / "ScrumTrace" / "agent.jsonl", {source.name for source, _ in selected.values()})

    result_bundle = output_root / "LocalExportReplay.xcresult"
    command = [
        "xcodebuild", "-project", str(REPO_ROOT / "ScrumTrace.xcodeproj"),
        "-scheme", "ScrumTrace", "-configuration", "Debug",
        "-derivedDataPath", str(derived_data), "-disableAutomaticPackageResolution",
        "-parallel-testing-enabled", "NO",
        "-destination", "platform=macOS,arch=arm64",
        "-resultBundlePath", str(result_bundle),
        "-only-testing:" + REPLAY_TEST,
        "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "ENABLE_DEBUG_DYLIB=NO", "test",
    ]
    environment = os.environ.copy()
    environment["TEST_RUNNER_SCRUMTRACE_REPLAY_SESSIONS_ROOT"] = str(replay_sessions)
    environment["SCRUMTRACE_REPLAY_SESSIONS_ROOT"] = str(replay_sessions)
    environment["CLANG_MODULE_CACHE_PATH"] = "/private/tmp/scrumtrace-local-export-clang-cache"
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = "/private/tmp/scrumtrace-local-export-swiftpm-cache"
    environment["SWIFTPM_PACKAGE_CACHE_PATH"] = "/private/tmp/scrumtrace-local-export-package-cache"
    run = subprocess.run(command, cwd=REPO_ROOT, env=environment, text=True, capture_output=True, check=False)
    log_path = output_root / "xcodebuild.log"
    log_path.write_text(run.stdout + "\n" + run.stderr, encoding="utf-8")
    os.chmod(log_path, 0o600)
    check_recording_lock(lock)
    check_processor_events(Path.home() / "Library" / "Logs" / "ScrumTrace" / "agent.jsonl", {source.name for source, _ in selected.values()})
    for source, before_hashes in selected.values():
        if before_hashes != tree_inventory(source):
            fail("A source hash or modification time changed during replay; no corpus pass is recorded.")
    if run.returncode != 0:
        fail("The selected Xcode replay test failed; its private log and result bundle were retained.")
    require_replay_xctest_passed(result_bundle)
    metrics_path = output_root / "private-replay-metrics.json"
    try:
        metrics_info = metrics_path.lstat()
        if stat.S_ISLNK(metrics_info.st_mode) or not stat.S_ISREG(metrics_info.st_mode):
            fail("The guarded replay did not create a regular private metrics file.")
        metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("The guarded replay metrics are missing or unreadable; no corpus pass is recorded.")
    os.chmod(metrics_path, 0o600)
    if (metrics.get("provider_factories") != 0 or metrics.get("provider_calls") != 0
            or metrics.get("transcriber_model_loads") != 0
            or len(metrics.get("fixtures", [])) != len(requested)):
        fail("The guarded replay metrics did not satisfy provider, transcription and fixture-count checks.")
    if {row.get("alias") for row in metrics["fixtures"]} != set(requested):
        fail("The guarded replay metrics do not match the requested private fixture aliases.")

    fixtures: list[dict[str, object]] = []
    hashes_unchanged = True
    for alias, (source, before_hashes) in selected.items():
        replay_session = replay_sessions / source.name
        consistency = validate_export(replay_session)
        baseline_export = output_root / "baseline" / "sessions" / source.name / "export"
        baseline_bytes = sum(
            path.stat().st_size for path in baseline_export.rglob("*")
            if path.is_file() and not path.is_symlink()
        ) if baseline_export.is_dir() else 0
        fixtures.append({
            "alias": alias,
            "source_files": len(before_hashes),
            "source_bytes": aggregate_bytes(before_hashes),
            "source_hashes_unchanged": True,
            "existing_export_bytes": baseline_bytes,
            **consistency,
        })
    report = {
        "status": "mechanical_replay_pass",
        "fixture_count": len(fixtures),
        "provider_calls": 0,
        "provider_factories": 0,
        "transcriber_model_loads": 0,
        "source_hashes_unchanged": hashes_unchanged,
        "human_semantic_acceptance": "pending",
        "export_only_human_exercise": "not_run",
        "fixtures": fixtures,
    }
    report_path = output_root / "private-summary.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    os.chmod(report_path, 0o600)
    print(f"Local export replay passed for {len(fixtures)} private copies; provider calls: 0; original source hashes unchanged.")
    print("Human semantic review and export-only consumer exercise remain separate acceptance items.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReplayError as error:
        print(f"local export replay stopped: {error}", file=sys.stderr)
        raise SystemExit(2)
