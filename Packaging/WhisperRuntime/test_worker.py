"""CPU-only contract checks with stdlib fakes. Never imports MLX/NumPy/models."""
import array
import hashlib
import importlib.util
import math
from pathlib import Path
import tempfile
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location('candidate_worker', Path(__file__).with_name('worker.py'))
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


class Samples(array.array):
    def __new__(cls, values=()):
        return super().__new__(cls, 'f', values)

    def copy(self):
        return Samples(self)


class Truth:
    def __init__(self, value):
        self.value = value

    def all(self):
        return self.value


class FakeNP:
    @staticmethod
    def frombuffer(data, dtype):
        assert dtype == '<f4'
        value = Samples()
        value.frombytes(data)
        return value

    @staticmethod
    def isfinite(data):
        return Truth(all(math.isfinite(x) for x in data))


class WorkerChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.job = self.root / str(uuid.uuid4())
        self.job.mkdir()
        self.model = self.root / 'model'
        self.model.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def request(self, frames, value=0.0):
        pcm = self.job / 'input.f32'
        pcm.write_bytes(Samples([value] * frames).tobytes())
        return dict(schemaVersion=1, requestID=self.job.name.upper(), pcmPath=str(pcm),
                    resultPath=str(self.job / 'result.json'), sampleRate=16000, frameCount=frames,
                    pcmSHA256=worker.sha256(pcm), fullTrackTimeOffset=0,
                    modelDirectory=str(self.model), modelIdentifier=worker.MODEL_ID,
                    modelRevision=worker.REVISION, decodingStrategyID=worker.STRATEGY,
                    languageMode='tr-en-mixed', allowNoSpeech=True)

    def run_request(self, request, decode, check=lambda: None):
        return worker.process_request(request, self.job, self.model, decode, FakeNP, check)

    def test_full_final_partial_window_is_processed(self):
        request = self.request(worker.WIDTH + 3)
        lengths = []
        def decode(audio):
            lengths.append(len(audio))
            return dict(language='tr', segments=[])
        reply = self.run_request(request, decode)
        self.assertEqual(lengths, [320000, 3])
        self.assertEqual(reply['processedFrameCount'], 320003)
        self.assertEqual([(x['startFrame'], x['endFrame']) for x in reply['windows']], [(0, 320000), (320000, 320003)])
        self.assertTrue(reply['complete'])

    def test_genuine_word_times_are_preserved(self):
        raw = dict(segments=[dict(text=' a b', start=1.0, end=2.0, words=[
            dict(word=' a', start=1.0, end=1.4), dict(word=' b', start=1.4, end=2.0)])])
        result = worker.convert_segments(raw, 20.0, 20.0)[0]
        self.assertEqual(result['words'][1], dict(text=' b', start=21.4, end=22.0))
        self.assertNotIn('wordTimingIssue', result)

    def test_real_numeric_scalar_types_are_normalized_not_rejected(self):
        class Scalar(float):
            pass
        raw = dict(segments=[dict(text=' a', start=Scalar(1), end=Scalar(2),
                   words=[dict(word=' a', start=Scalar(1), end=Scalar(2))])])
        result = worker.convert_segments(raw, 0, 20)[0]
        self.assertEqual(result['words'][0]['end'], 2.0)
        self.assertIs(type(result['words'][0]['end']), float)

    def test_invalid_words_are_omitted_but_segment_preserved(self):
        for words in (None, [], [dict(word=' a', start=0.9, end=2.1)],
                      [dict(word=' other', start=1.0, end=2.0)],
                      [dict(word=' a', start=float('nan'), end=2.0)]):
            raw = dict(segments=[dict(text=' a', start=1.0, end=2.0, words=words)])
            result = worker.convert_segments(raw, 20.0, 20.0)[0]
            self.assertEqual((result['text'], result['start'], result['end']), (' a', 21.0, 22.0))
            self.assertNotIn('words', result)
            self.assertIn(result['wordTimingIssue'], ('missing', 'invalid'))

    def test_cancel_after_decode_never_publishes_complete_result(self):
        request = self.request(16000)
        cancelled = [False]
        def check():
            worker.require(not cancelled[0], 'cancelled')
        def decode(audio):
            cancelled[0] = True
            return dict(segments=[])
        with self.assertRaises(worker.Failure):
            self.run_request(request, decode, check)
        self.assertFalse((self.job / 'result.json').exists())

    def test_nonfinite_input_never_reaches_decoder(self):
        request = self.request(1, float('nan'))
        def forbidden(audio):
            self.fail('decoder must not see nonfinite samples')
        with self.assertRaises(worker.Failure):
            self.run_request(request, forbidden)

    def test_changed_input_is_not_published(self):
        request = self.request(16000)
        def decode(audio):
            with Path(request['pcmPath']).open('ab') as output:
                output.write(b'\x00\x00\x00\x00')
            return dict(segments=[])
        with self.assertRaises(worker.Failure):
            self.run_request(request, decode)
        self.assertFalse((self.job / 'result.json').exists())

    def test_result_path_and_strategy_fail_closed(self):
        request = self.request(1)
        for key, value in [('resultPath', str(self.root / 'outside.json')),
                           ('languageMode', 'tr'), ('pcmSHA256', '0' * 64),
                           ('frameCount', 2), ('fullTrackTimeOffset', 10)]:
            changed = dict(request, **{key: value})
            with self.assertRaises(worker.Failure):
                worker.validate_request(changed, self.job, self.model)

    def test_segment_outside_source_is_rejected_without_clamping(self):
        with self.assertRaises(worker.Failure):
            worker.convert_segments(dict(segments=[dict(text='a', start=0, end=20.001)]), 0, 20)

    def test_reversed_zero_duration_fragments_keep_text_and_times(self):
        raw = dict(segments=[dict(text='late', start=19.98, end=19.98),
                             dict(text='early', start=19.96, end=19.96)])
        result = worker.convert_segments(raw, 20, 20)
        self.assertEqual([(x['text'], x['start'], x['end']) for x in result],
                         [('early', 39.96, 39.96), ('late', 39.980000000000004, 39.980000000000004)])

    def test_empty_upstream_placeholders_are_not_transcript_segments(self):
        self.assertEqual(worker.convert_segments(dict(segments=[
            dict(text='', start=19.96, end=19.96), dict(text=' ', start=20.0, end=20.0)]), 0, 20), [])

    def test_no_speech_policy_and_replay(self):
        request = self.request(1)
        with self.assertRaises(worker.Failure):
            self.run_request(dict(request, allowNoSpeech=False), lambda audio: dict(segments=[]))
        self.run_request(request, lambda audio: dict(segments=[]))
        with self.assertRaises(worker.Failure):
            self.run_request(request, lambda audio: dict(segments=[]))


if __name__ == '__main__':
    unittest.main()
