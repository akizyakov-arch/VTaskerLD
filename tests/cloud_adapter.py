import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import wave

spec = importlib.util.spec_from_file_location('cloud', Path(__file__).parents[1] / 'scripts/cloud-transcribe.py')
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)

class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.audio = Path(self.tmp.name) / 'audio.wav'
        self.output = Path(self.tmp.name) / 'result.json'
        with wave.open(str(self.audio), 'wb') as wav:
            wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            wav.writeframes(b'\x00\x00' * 16000)
        self.env = patch.dict(os.environ, {'VTRACKER_CLOUD_URL': 'https://example.invalid/v1/audio/transcriptions', 'VTRACKER_CLOUD_MODEL': 'whisper-1', 'VTRACKER_CLOUD_KEY': 'test-secret'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_response(self, value):
        def send(request, timeout):
            self.assertEqual(request.get_header('Authorization'), 'Bearer test-secret')
            self.assertIn(b'name="file"', request.data)
            self.assertIn(b'name="model"', request.data)
            return io.BytesIO(json.dumps(value).encode())
        with patch.object(cloud.urllib.request.OpenerDirector, 'open', side_effect=send):
            cloud.transcribe(self.audio, self.output)
        return json.loads(self.output.read_text())

    def test_plain_text_has_explicit_whole_recording_timing(self):
        result = self.run_response({'text': 'Проверка записи'})
        self.assertFalse(result['cloud_segment_timestamps'])
        self.assertEqual(result['transcription'][0]['offsets'], {'from': 0, 'to': 1000})

    def test_segment_timing_is_preserved(self):
        result = self.run_response({'segments': [{'start': 0.1, 'end': 0.9, 'text': 'Привет'}]})
        self.assertTrue(result['cloud_segment_timestamps'])
        self.assertEqual(result['transcription'][0]['offsets'], {'from': 100, 'to': 900})

    def test_http_failure_does_not_publish_result_or_secret(self):
        failure = urllib.error.HTTPError('https://example.invalid', 401, 'private', {}, None)
        with patch.object(cloud.urllib.request.OpenerDirector, 'open', side_effect=failure):
            with self.assertRaisesRegex(ValueError, 'HTTP 401') as result:
                cloud.transcribe(self.audio, self.output)
        self.assertNotIn('test-secret', str(result.exception))
        self.assertFalse(self.output.exists())

    def test_empty_response_is_an_error(self):
        with self.assertRaises(ValueError):
            self.run_response({'text': ''})

    def test_redirect_is_not_followed(self):
        with patch.object(cloud.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = io.BytesIO(b'{"text":"ok"}')
            cloud.transcribe(self.audio, self.output)
            handler = opener.call_args.args[0]
            self.assertIsNone(handler.redirect_request(None, None, None, None, None, None))

if __name__ == '__main__':
    unittest.main()
