#!/usr/bin/env python3
"""Run only the prebuilt, opt-in production SwiftUI snapshot test with a hard deadline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--renderer", choices=["hosting", "swiftui"], default="hosting")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error("Timeout must be 1–60 seconds.")
    repo = args.repo.resolve()
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a fresh output directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    fixture = repo / "Tests/MeetingDeskTests/WorkspaceFixtures/synthetic-fixtures.json"
    test_source = repo / "Tests/MeetingDeskTests/WorkspaceVisualSnapshotTests.swift"
    if not test_source.is_file():
        parser.error("Copy the prepared snapshot test into the repository and build tests first.")
    env = dict(os.environ)
    env.update({"MEETINGDESK_UI_SNAPSHOT_DIR": str(output),
                "MEETINGDESK_UI_FIXTURE_PATH": str(fixture),
                "MEETINGDESK_UI_RENDERER": args.renderer,
                "CLANG_MODULE_CACHE_PATH": str(repo / ".build/ModuleCache"),
                "SWIFT_MODULECACHE_PATH": str(repo / ".build/ModuleCache")})
    command = ["swift", "test", "--skip-build", "--disable-sandbox", "--disable-keychain",
               "--cache-path", ".build/cache", "--scratch-path", ".build", "--filter",
               "WorkspaceVisualSnapshotTests.testRenderProductionWorkspaceInBothAppearancesAndWindowSizes"]
    sources = [test_source, repo / "Sources/MeetingDesk/RootView.swift"]
    sources += sorted((repo / "Sources/MeetingDesk").glob("*Theme*.swift"))
    sources += sorted((repo / "Sources/MeetingDesk").glob("Workspace*.swift"))
    proof = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"],
              cwd=repo, text=True).strip(), "fixtureSHA256": sha(fixture),
             "sources": {str(p.relative_to(repo)): sha(p) for p in sources},
             "renderer": args.renderer, "timeoutSeconds": args.timeout,
             "actualProductionView": "RootView", "syntheticOnly": True,
             "visibleAppRequested": False, "desktopScreenshotRequested": False,
             "modelInferenceRequested": False, "realArchiveRequested": False}
    started = time.monotonic()
    process = subprocess.Popen(command, cwd=repo, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        stdout, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, _ = process.communicate()
    proof.update({"exitCode": process.returncode, "timedOut": timed_out,
                  "elapsedSeconds": round(time.monotonic() - started, 3)})
    report = output / "render-report.json"
    proof["renderReportExists"] = report.is_file()
    proof["passed"] = process.returncode == 0 and not timed_out and report.is_file()
    log = output.parent / (output.name + "-run.log")
    source_proof = output.parent / (output.name + "-proof.json")
    log.write_bytes(stdout)
    source_proof.write_text(json.dumps(proof, indent=2) + "\n")
    log.chmod(0o600)
    source_proof.chmod(0o600)
    print(json.dumps({"passed": proof["passed"], "exitCode": process.returncode,
                      "timedOut": timed_out, "output": str(output),
                      "log": str(log), "proof": str(source_proof)}))
    raise SystemExit(0 if proof["passed"] else 1)


if __name__ == "__main__":
    main()
