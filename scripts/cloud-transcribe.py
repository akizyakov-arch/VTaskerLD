"""OpenAI-compatible transcription adapter. Secrets enter through environment only."""
import json
import os
import sys
import urllib.request
import urllib.error
import uuid
import wave
from pathlib import Path


def transcribe(audio, output):
    path = Path(audio)
    if path.stat().st_size > 24 * 1024 * 1024:
        raise ValueError('Облачная запись превышает 24 МБ. Используйте локальную модель или более короткую запись.')
    boundary = 'vtask-' + uuid.uuid4().hex
    parts = []
    for name, value in [('model', os.environ['VTRACKER_CLOUD_MODEL']),
                        ('language', os.environ.get('VTRACKER_LANGUAGE', 'ru')),
                        ('response_format', os.environ.get('VTRACKER_CLOUD_FORMAT', 'json'))]:
        if name == 'language' and os.environ['VTRACKER_CLOUD_MODEL'] == 'gpt-transcribe':
            continue
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="recording.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + path.read_bytes() + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    request = urllib.request.Request(os.environ['VTRACKER_CLOUD_URL'], data=b''.join(parts), headers={
        'Authorization': 'Bearer ' + os.environ['VTRACKER_CLOUD_KEY'],
        'Content-Type': 'multipart/form-data; boundary=' + boundary})
    # Never forward credentials to a redirect target.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=600) as response:
            data = json.loads(response.read(8 * 1024 * 1024))
    except urllib.error.HTTPError as error:
        raise ValueError(f'Облачный API вернул HTTP {error.code}; проверьте адрес, модель, ключ и лимиты.') from None
    with wave.open(str(path)) as wav:
        duration = wav.getnframes() / wav.getframerate()
    segments = data.get('segments')
    timing = isinstance(segments, list) and bool(segments)
    if not timing:
        if not isinstance(data.get('text'), str) or not data['text'].strip():
            raise ValueError('Облачный API не вернул текст распознавания.')
        segments = [{'start': 0, 'end': duration, 'text': data['text']}]
    result = {'transcription': [{'offsets': {'from': round(s['start'] * 1000), 'to': round(s['end'] * 1000)}, 'text': s['text']} for s in segments], 'cloud_segment_timestamps': timing}
    Path(output).write_text(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        transcribe(sys.argv[1], sys.argv[2])
    except Exception as error:
        # Only deliberately sanitized errors are published; network errors can contain URLs.
        message = str(error) if isinstance(error, ValueError) else 'Не удалось связаться с облачным API или прочитать ответ.'
        Path(sys.argv[2] + '.error').write_text(message)
        sys.exit(1)
