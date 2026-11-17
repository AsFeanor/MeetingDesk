Build the app-owned offline Whisper runtime from the pinned standalone CPython archive and exact wheel artifacts. The first release retains the complete Torch wheel. These tools never download model weights, read meetings, or run inference.

From the repository root, use Python3.12 for the build tools:

```sh
ASR_ARTIFACTS="$PWD/.build/whisper-artifacts"
ASR_RUNTIME="$PWD/.build/whisper-runtime"
python3.12 Packaging/WhisperRuntime/fetch_artifacts.py --destination "$ASR_ARTIFACTS"
python3.12 Packaging/WhisperRuntime/build_runtime.py --artifacts "$ASR_ARTIFACTS" --destination "$ASR_RUNTIME" --worker Packaging/WhisperRuntime/worker.py --quality-accepted
python3.12 Packaging/WhisperRuntime/finalize_runtime.py --runtime "$ASR_RUNTIME"
MEETINGDESK_ASR_RUNTIME="$ASR_RUNTIME" zsh Packaging/build.sh dist/local
```

The destination must be fresh. Fetching is the only network step; every supplier URL and SHA256 is frozen in python-provenance.json and wheel-provenance.json. Assembly verifies the artifacts and uses the extracted standalone interpreter with pinned pip, `--no-index --no-deps --no-compile`. It never copies a developer venv. The fixed runtime is CPython3.12.12, mlx-whisper0.4.3, MLX0.32.4 and their exact recorded dependencies. MLX wheels require macOS26 arm64.

Native audit parses actual LC_LOAD commands separately from image IDs and fat architecture headers. It resolves bundled dependencies using the current image's loader paths and actual load ancestry. The recorded cleanup removes three unused SciPy Homebrew fallback RPATHs and gives Numba's OpenMP backend a relative RPATH to the pinned bundled Torch library. Source/post-transform hashes, native architecture/minimumOS/load paths, exact files and copied license notices are recorded. Finalization verifies the complete previous inventory before changes and does not reinstall packages. Build logs and local model-directory metadata are removed.

Packaging/build.sh requires MEETINGDESK_ASR_RUNTIME. Before signing the enclosing app, embed_runtime.py verifies the finalized inventory, copies only Contents/Resources/ASRRuntime and signs its native code inside out using the build's identity. An optional MEETINGDESK_ASR_ENTITLEMENTS file passes explicitly reviewed interpreter entitlements to this hook. The main app is then signed and checked by the existing packaging flow. runtime-manifest.json records pre-sign hashes; runtime-signatures.json records signed native hashes. Human quality acceptance is separate from signed relocation, offline execution and cancellation acceptance.

Model weights stay outside the app and update archive. The app's model store downloads and verifies the pinned config/weights once under Application Support/MeetingDeskModels/WhisperLargeTurbo/<revision> when the user chooses Prepare. model-provenance.json contains public repository/revision/checksum metadata only. No developer path, archive, transcript or recording is bundled.

The app launches ASRRuntime/python/bin/python3.12 with `-I -B`, ASRRuntime/worker.py, `--session-directory` and a verified local `--model` path. Do not set PYTHONHOME/PYTHONPATH or look up Python through PATH. One app-owned process serializes both source tracks and retains one model session. Private file IPC uses jobs/<UUID>/request.json and atomic result.json/progress.json/error.json; root finish/cancel sentinels close the owned session. The Swift adapter checks request/model/PCM identities and complete frame counts before committing.

Decoding remains the accepted `window-auto-20s-v1` candidate: seed0, temperature0, auto language per20secondwindow, word timestamps, no previous-text conditioning, no prompt and fp16. Every source frame, including the final partial window, is processed. Valid text/segment times remain available when a word list is missing or unsafe; the worker marks the issue and never invents timing. Empty upstream placeholders are omitted, and real fragments are sorted chronologically without changing their timestamps. Timing-flagged segments retain source labels rather than inferred individual-speaker attribution.

Run the CPU-only packaging/IPC checks with the repository's existing command:

```sh
python3 -m unittest discover -s Packaging -p 'test_*.py'
```

These tests import no models/MLX and do not replace the signed packaged-app offline and cancellation checks.
