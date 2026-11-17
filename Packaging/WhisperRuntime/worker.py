#!/usr/bin/env python3
"""Candidate IPC1 worker. App-owned, offline, sequential; never an idle service."""
import argparse
import contextlib
import hashlib
import importlib.abc
import importlib.metadata
import json
import math
import numbers
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
import uuid

RATE = 16000
WIDTH = RATE * 20
MODEL_ID = 'mlx-community/whisper-large-v3-turbo'
REVISION = 'a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'
MODEL_SHA = '951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6'
CONFIG_SHA = 'b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379'
IMPLEMENTATION = 'mlx-whisper-0.4.3+meetingdesk-ipc1'
STRATEGY = 'window-auto-20s-v1'
OPTIONS = dict(task='transcribe', language=None, temperature=0.0,
               word_timestamps=True, condition_on_previous_text=False,
               initial_prompt=None, verbose=False, fp16=True,
               compression_ratio_threshold=2.4, logprob_threshold=-1.0,
               no_speech_threshold=0.6)


class Failure(Exception):
    def __init__(self, code):
        self.code = code


def require(condition, code):
    if not condition:
        raise Failure(code)


def sha256(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.part')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False,
                      separators=(',', ':'))
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    require(not path.is_symlink() and path.is_file() and path.stat().st_size <= 65536,
            'invalid-request-file')
    return json.loads(path.read_text(encoding='utf-8'))


def validate_request(request, job, model):
    require(isinstance(request, dict) and request.get('schemaVersion') == 1, 'schema')
    try:
        identity = str(uuid.UUID(request['requestID']))
    except (ValueError, TypeError, KeyError, AttributeError):
        raise Failure('request-identity')
    require(identity == job.name.lower(), 'request-identity')
    require(request.get('sampleRate') == RATE and type(request.get('frameCount')) is int
            and 0 < request['frameCount'] <= RATE * 86400, 'pcm-format')
    require(request.get('fullTrackTimeOffset') == 0, 'unsupported-time-offset')
    require(request.get('modelIdentifier') == MODEL_ID and request.get('modelRevision') == REVISION
            and request.get('modelDirectory') == str(model), 'model-identity')
    require(request.get('decodingStrategyID') == STRATEGY
            and request.get('languageMode') == 'tr-en-mixed', 'unaccepted-strategy')
    require(type(request.get('allowNoSpeech')) is bool, 'no-speech-policy')
    expected = request.get('pcmSHA256')
    require(isinstance(expected, str) and re.fullmatch('[0-9a-f]{64}', expected), 'pcm-digest')
    pcm = Path(request.get('pcmPath', ''))
    result = Path(request.get('resultPath', ''))
    require(pcm.is_absolute() and pcm.parent == job and not pcm.is_symlink()
            and pcm.is_file() and stat.S_ISREG(pcm.stat().st_mode), 'pcm-path')
    require(result == job / 'result.json' and not result.exists()
            and not result.is_symlink(), 'result-path')
    require(pcm.stat().st_size == request['frameCount'] * 4
            and sha256(pcm) == expected, 'pcm-integrity')
    return pcm, result


def finite(value):
    return isinstance(value, numbers.Real) and not isinstance(value, bool) and math.isfinite(value)


def convert_segments(raw, offset, duration):
    """Retain model segment times; never interpolate or clamp word timestamps."""
    segments = []
    for segment in raw.get('segments', []):
        start, end, text = segment.get('start'), segment.get('end'), segment.get('text')
        require(isinstance(text, str), 'segment-text')
        # Upstream emits empty zero-duration placeholders; they contain no text
        # and are not user transcript segments or missing alignment evidence.
        if not text.strip():
            continue
        require(finite(start) and finite(end) and 0 <= start <= end <= duration, 'segment-timing')
        start, end = float(start), float(end)
        result = dict(text=text, start=start + offset, end=end + offset)
        words = segment.get('words')
        issue = 'missing' if not words else None
        converted = []
        prior_start, prior_end = -1.0, -1.0
        for word in words or []:
            lower, upper, token = word.get('start'), word.get('end'), word.get('word')
            valid = (finite(lower) and finite(upper) and start <= lower <= upper <= end
                     and lower >= prior_start and upper >= prior_end
                     and isinstance(token, str) and bool(token))
            if not valid:
                issue = 'invalid'
                break
            lower, upper = float(lower), float(upper)
            converted.append(dict(text=token, start=lower + offset, end=upper + offset))
            prior_start, prior_end = lower, upper
        if words and ''.join(word['text'] for word in converted).strip() != text.strip():
            issue = 'invalid'
        if issue:
            result['wordTimingIssue'] = issue
        else:
            result['words'] = converted
        segments.append(result)
    # The real trial contained one reversed pair of zero-duration fragments.
    # Preserve every fragment and its genuine times; emit chronological order.
    return sorted(segments, key=lambda x: (x['start'], x['end']))


def process_request(request, job, model, decoder, np, check_cancel):
    pcm, result_path = validate_request(request, job, model)
    count = request['frameCount']
    segments, windows, processed = [], [], 0
    with pcm.open('rb') as source:
        before = os.fstat(source.fileno())
        while processed < count:
            check_cancel()
            frames = min(WIDTH, count - processed)
            data = source.read(frames * 4)
            require(len(data) == frames * 4, 'pcm-incomplete')
            audio = np.frombuffer(data, dtype='<f4').copy()
            require(bool(np.isfinite(audio).all()), 'pcm-nonfinite')
            raw = decoder(audio)
            check_cancel()
            shifted = convert_segments(raw, processed / RATE, frames / RATE)
            segments.extend(shifted)
            windows.append(dict(startFrame=processed, endFrame=processed + frames,
                                detectedLanguage=raw.get('language')))
            processed += frames
            atomic_json(job / 'progress.json', dict(schemaVersion=1, requestID=request['requestID'],
                        processedFrameCount=processed, sourceFrameCount=count, complete=False))
        require(source.read(1) == b'', 'pcm-size-changed')
        after = os.fstat(source.fileno())
        require((before.st_ino, before.st_dev, before.st_size, before.st_mtime_ns) ==
                (after.st_ino, after.st_dev, after.st_size, after.st_mtime_ns), 'pcm-changed')
    require(sha256(pcm) == request['pcmSHA256'], 'pcm-changed')
    require(request['allowNoSpeech'] or bool(segments), 'no-speech')
    check_cancel()
    reply = dict(schemaVersion=1, requestID=request['requestID'], backend='mlx-whisper',
                 modelIdentifier=MODEL_ID, modelRevision=REVISION,
                 implementationVersion=IMPLEMENTATION, decodingStrategyID=STRATEGY,
                 languageMode=request['languageMode'], sampleRate=RATE,
                 sourceFrameCount=count, processedFrameCount=processed, complete=True,
                 pcmSHA256=request['pcmSHA256'], windows=windows, segments=segments,
                 segmentsWithoutSafeWords=sum('wordTimingIssue' in x for x in segments))
    atomic_json(result_path, reply)
    return reply


class OfflineGuard(importlib.abc.MetaPathFinder):
    def __init__(self):
        self.attempts = []

    def find_spec(self, fullname, path=None, target=None):
        if fullname == 'torch' or fullname.startswith('torch.'):
            self.attempts.append(fullname)
            raise ModuleNotFoundError('Torch disabled in this transcription-only worker')
        return None


def deny_external_operations(event, arguments):
    if event in ('socket.connect', 'socket.getaddrinfo', 'socket.bind',
                 'subprocess.Popen', 'os.system', 'os.posix_spawn'):
        raise Failure('external-operation-denied')


def run(args):
    os.umask(0o077)
    session = args.session_directory.absolute()
    require(session.is_dir() and not session.is_symlink()
            and session.resolve() == session and session.stat().st_uid == os.geteuid()
            and session.stat().st_mode & 0o077 == 0, 'private-session-required')
    jobs = session / 'jobs'
    jobs.mkdir(mode=0o700, exist_ok=True)
    require(not jobs.is_symlink() and jobs.resolve().parent == session, 'jobs-path')
    require(not (session / 'status.json').exists(), 'fresh-session-required')
    model = args.model.absolute()
    require(model.resolve() == model and model.is_dir()
            and not (model / 'weights.safetensors').is_symlink()
            and not (model / 'config.json').is_symlink(), 'local-model-required')
    require(sha256(model / 'weights.safetensors') == MODEL_SHA
            and sha256(model / 'config.json') == CONFIG_SHA, 'model-integrity')
    os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
                      TRANSFORMERS_OFFLINE='1', TOKENIZERS_PARALLELISM='false',
                      NUMBA_CACHE_DIR=str(session / 'numba-cache'),
                      XDG_CACHE_HOME=str(session / 'cache'))
    cancelled, completed, processed_jobs = False, [], set()
    started, idle_since, parent = time.monotonic(), time.monotonic(), os.getppid()

    def on_signal(number, frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    def check_cancel():
        require(not cancelled and not (session / 'cancel').exists()
                and os.getppid() == parent, 'cancelled')
        require(time.monotonic() - started < 7200, 'session-deadline')

    require(not any(x == 'torch' or x.startswith('torch.') for x in sys.modules), 'torch-preloaded')
    guard = OfflineGuard()
    sys.meta_path.insert(0, guard)
    sys.addaudithook(deny_external_operations)
    atomic_json(session / 'status.json', dict(schemaVersion=1, state='ready', modelLoaded=False))
    decoder, np, failure, active_job, active_request = None, None, None, None, None
    try:
        while True:
            check_cancel()
            pending = []
            for child in sorted(jobs.iterdir()):
                if child.name in processed_jobs:
                    continue
                require(child.is_dir() and not child.is_symlink() and child.resolve().parent == jobs,
                        'invalid-job-directory')
                if (child / 'request.json').exists():
                    pending.append(child)
            require(len(pending) <= 1, 'overlapping-requests')
            if pending:
                job = pending[0]
                active_job, active_request = job, None
                request = read_json(job / 'request.json')
                active_request = request.get('requestID') if isinstance(request, dict) else None
                # Validate inputs before importing any GPU/model libraries.
                validate_request(request, job, model)
                atomic_json(session / 'status.json', dict(schemaVersion=1, state='working',
                            requestID=request['requestID'], modelLoaded=decoder is not None))
                if decoder is None:
                    require(importlib.metadata.version('mlx-whisper') == '0.4.3'
                            and importlib.metadata.version('mlx') == '0.32.4', 'runtime-version')
                    import numpy as np
                    import mlx.core as mx
                    import mlx_whisper
                    require(bool(mx.metal.is_available()), 'metal-unavailable')
                    mx.random.seed(0)
                    mx.set_default_device(mx.gpu)
                    decoder = lambda audio: mlx_whisper.transcribe(audio, path_or_hf_repo=str(model), **OPTIONS)
                completed.append(process_request(request, job, model, decoder, np, check_cancel))
                processed_jobs.add(job.name)
                active_job, active_request = None, None
                idle_since = time.monotonic()
                atomic_json(session / 'status.json', dict(schemaVersion=1, state='ready', modelLoaded=True))
            elif (session / 'finish').exists():
                break
            else:
                require(time.monotonic() - idle_since < 60, 'session-idle-deadline')
                time.sleep(0.1)
    except Failure as error:
        failure = error.code
    except Exception:
        failure = 'worker-failed'
    finally:
        if failure and active_job is not None:
            atomic_json(active_job / 'error.json', dict(schemaVersion=1, requestID=active_request,
                        errorCode=failure, complete=False))
        atomic_json(session / 'audit.json', dict(schemaVersion=1, workerSHA256=sha256(Path(__file__)),
                    modelSHA256=MODEL_SHA, configSHA256=CONFIG_SHA, workerCompleted=failure is None,
                    deniedTorchImports=guard.attempts,
                    torchLoadedAfter=sorted(x for x in sys.modules if x == 'torch' or x.startswith('torch.')),
                    offline=True, fullFramesComplete=bool(completed) and all(x['complete'] for x in completed),
                    wordTimestamps=True, decodingStrategyID=STRATEGY, decodeOptions=OPTIONS, seed=0,
                    completedRequests=len(completed), qualityAcceptance='external-user-gate'))
        atomic_json(session / 'status.json', dict(schemaVersion=1, state='closed',
                    success=failure is None, errorCode=failure, completedRequests=len(completed)))
    return 0 if failure is None else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session-directory', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    args = parser.parse_args()
    # Suppress package progress/content output; no meeting text in process pipes.
    os.umask(0o077)
    with open(os.devnull, 'w') as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
        try:
            return run(args)
        except Exception:
            return 2


if __name__ == '__main__':
    sys.exit(main())
