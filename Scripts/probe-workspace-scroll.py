#!/usr/bin/env python3
"""Run only the prebuilt native workspace scroll probe; never build or inspect user archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def displaced(scenario):
    return any(item.get("scrollBridgeAccessible") is True
               and item.get("scrollDisplacementVerified") is True
               and item.get("maximumVerticalExtent", 0) > 0
               and item.get("actualOffsetChanges", 0) > 0
               for item in scenario.get("scrollViews", []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output_dir.resolve()
    source = repo / "Tests/MeetingDeskTests/WorkspaceScrollPerformanceProbeTests.swift"
    if not source.is_file() or not (repo / ".build").is_dir():
        parser.error("Install the opt-in test and build tests first; this runner never builds.")
    if output.exists():
        parser.error("Choose a fresh output directory that does not already exist.")
    output.mkdir(mode=0o700, parents=True)
    temporary = output / "tmp"
    temporary.mkdir(mode=0o700)
    report_path, log_path = output / "scroll-report.json", output / "run.log"
    env = dict(os.environ)
    env.update({"MEETINGDESK_SCROLL_PROBE_OUTPUT": str(report_path), "TMPDIR": str(temporary) + "/",
                "CLANG_MODULE_CACHE_PATH": str(repo / ".build/ModuleCache"),
                "SWIFT_MODULECACHE_PATH": str(repo / ".build/ModuleCache")})
    command = ["swift", "test", "--skip-build", "--disable-sandbox", "--disable-keychain",
               "--cache-path", ".build/cache", "--scratch-path", ".build", "--filter",
               "WorkspaceScrollPerformanceProbeTests.testDetachedProductionWorkspaceIdleAndScroll"]
    proof = {"timeoutSeconds": 35, "executionBudgetSeconds": 32, "syntheticOnly": True,
             "buildRequested": False, "physicalInputTested": False, "liveAppAcceptance": False,
             "sourceHashIsBuildProof": False, "prebuiltArtifactsAssumedCurrent": True,
             "testSourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest()}
    started, timed_out, execution_error, process = time.monotonic(), False, None, None
    with log_path.open("xb") as log:
        log_path.chmod(0o600)
        try:
            process = subprocess.Popen(command, cwd=repo, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=32)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired) as error:
            execution_error = type(error).__name__
    valid, checks, report_error = False, {}, None
    try:
        report = json.loads(report_path.read_text())
        scenarios = {item["scenario"]: item for item in report["scenarios"]}
        root, transcript = scenarios["productionRootView.overview"], scenarios["productionTranscriptWorkspaceView"]
        work = transcript.get("workCountsTotal", {})
        checks = {"rootScrollVerified": displaced(root), "transcriptScrollVerified": displaced(transcript),
                  "transcriptPrepared": transcript.get("transcriptPreparationObserved") is True
                      and all(work.get(key, 0) >= 1 for key in ("transcriptPrepare", "transcriptGroup", "transcriptRow")),
                  "transcriptReady": transcript.get("transcriptReadinessVerified") is True,
                  "syntheticArchiveUnchanged": report.get("synthetic") is True and report.get("archiveUnchanged") is True}
        valid = all(checks.values())
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        report_error = type(error).__name__
    proof.update({"exitCode": process.returncode if process else None, "timedOut": timed_out,
                  "elapsedSeconds": round(time.monotonic() - started, 3), "executionError": execution_error,
                  "reportExists": report_path.is_file(), "reportError": report_error, "checks": checks})
    proof["passed"] = process is not None and process.returncode == 0 and not timed_out and not execution_error and valid
    proof_path = output / "probe-proof.json"
    proof_path.write_text(json.dumps(proof, indent=2) + "\n")
    proof_path.chmod(0o600)
    print(json.dumps({"passed": proof["passed"], "timedOut": timed_out, "proof": str(proof_path), "log": str(log_path)}))
    raise SystemExit(0 if proof["passed"] else 1)


if __name__ == "__main__":
    main()
