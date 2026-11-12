# Opt-in public speaker model check

Ordinary tests do not download models or read audio fixtures. The integration
check is explicitly enabled with `MEETINGDESK_SPEAKER_MODEL_CHECK=1` and takes
`MEETINGDESK_SPEAKER_FIXTURE_ROOT` (the directory below),
`MEETINGDESK_SPEAKER_MODEL_CACHE` (a dedicated local model cache), and optional
`MEETINGDESK_SPEAKER_REPORT_PATH` (counts/scores only, no embeddings).

Source: FluidInference/FluidAudio v0.18.3,
commit `c8b41f98eae668794dd0083bbe028fe7e6585051`.
Directory: `Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures`.
https://github.com/FluidInference/FluidAudio/tree/v0.18.3/Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures

The test reads these exact existing public recordings by SHA-256:

| Input | SHA-256 | Purpose |
| --- | --- | --- |
| Vocabulary/quilter.wav | 799f78ed4beb4de7ceae3a809262d4ce242394342ccd1d58cef7d49dbc2def46 | Enrollment; LibriSpeech speaker 1272, utterance 1272-128104-0000 |
| Vocabulary/quilter-possessive.wav | 473b1bb573e8f7cdcd639c6e318036236190107b66bfe6892286121a92d464c1 | Independent content, same documented LibriSpeech speaker, utterance 1272-128104-0001 |
| 03-diff-explanation-16.9s.wav | 83f670fa70b12e64a1c5195d948937605c0e4786d5cefea3d3feb0b3b47cde36 | Different real voice from FluidAudio's public ASR fixtures |

LibriSpeech attribution: Vassil Panayotov, Guoguo Chen, Daniel Povey and
Sanjeev Khudanpur, https://www.openslr.org/12, CC BY 4.0.
The pinned fixture's `Vocabulary/README.md` and `LICENSE_CC_BY_4_0.txt`
document the corpus, validation-subset revision and audio hashes.
The source for clip 03 is FluidAudio's public fixture; its tagged Package.swift
explicitly describes these real recordings as cleared for public release by
the speaker. No separate recording license is present in that fixture folder;
this project references the existing file for local checks and does not
redistribute it or include any fixture audio in the app or this source tree.

The two-speaker input is a controlled A/B/A concatenation of human speech with
silence gaps. It is not a natural meeting, a microphone-capture check, a
Turkish accuracy benchmark, or evidence of universal recognition performance.
The profile is saved only inside the disposable test directory. No user
meeting archive or real voice profile store is opened. Reports contain only
aggregate scores/counts/model identity; no audio, transcript or embedding.
