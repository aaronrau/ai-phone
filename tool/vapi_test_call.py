"""Place a real test call to the phone from a Vapi assistant that plays the caller.

The Vapi side is only a test harness on the computer; the receptionist itself
stays fully on-device. Secrets and phone numbers are never written to the repo:
  - VAPI_API is read from the environment or the git-ignored `.env`.
  - The destination comes from --to or the private file given by --to-file.

Usage:
  python3 -B tool/vapi_test_call.py --scenario probe --phone-number-id <id> \
      --to-file ~/.cache/android-ai-receptionist/state/phone-number.txt \
      --output /tmp/receptionist-call-001

Scenarios are defined in SCENARIOS below. The report (transcript, messages,
ended reason, timings) is written to <output>/report.json.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = 'https://api.vapi.ai'

PROBE_TEXT = (
    'Hello, this is the audio test caller. I will keep talking for a while so the phone can measure '
    'how well it hears me. One, two, three, four, five, six, seven, eight, nine, ten. '
    'The quick brown fox jumps over the lazy dog. A journey of a thousand miles begins with a single step. '
    'Eleven, twelve, thirteen, fourteen, fifteen, sixteen, seventeen, eighteen, nineteen, twenty. '
    'She sells sea shells by the sea shore, and the shells she sells are surely sea shells. '
    'Twenty one, twenty two, twenty three, twenty four, twenty five, twenty six, twenty seven. '
    'Peter Piper picked a peck of pickled peppers. How much wood would a woodchuck chuck. '
    'Thirty, thirty one, thirty two, thirty three, thirty four, thirty five. That is the end of my reading.'
)

SCENARIOS = {
    # Continuous speech for the on-device audio probe; afterwards stays quiet so
    # Vapi's transcript captures which playback tests reached the caller.
    'probe': {
        'firstMessage': PROBE_TEXT,
        'system': 'You are a test caller. You have already read your passage. From now on say nothing at all '
                  'unless someone asks you a direct question; then answer with one or two words. Never end the call.',
        'maxDurationSeconds': 150,
    },
    # Short speech (for downlink capture), then silence so the transcript shows
    # exactly what the phone plays into the call.
    'probe_short': {
        'firstMessage': 'Hello, this is the audio test caller. One, two, three, four, five. '
                        'The quick brown fox jumps over the lazy dog.',
        'system': 'You are a silent test listener. After your first sentence, never speak again, whatever you hear. '
                  'Never end the call.',
        'maxDurationSeconds': 90,
    },
    # About 25 s of speech for downlink capture, then silence for uplink tests.
    'probe_medium': {
        'firstMessage': PROBE_TEXT.split(' Twenty one')[0],
        'system': 'You are a silent test listener. After your first message, never speak again, whatever you hear. '
                  'Never end the call.',
        'maxDurationSeconds': 100,
    },
    'known': {
        'firstMessage': '',
        'system': 'You are Jordan, calling your sibling Sam. An assistant will answer. Wait for the greeting. '
                  'Ask whether Sam is free on Monday afternoon for coffee. Then ask the assistant to tell Sam that '
                  'Jordan called and to call back tonight. When the assistant confirms, say thanks and goodbye. '
                  'Speak naturally in short sentences, one at a time, and wait for answers.',
        'maxDurationSeconds': 180,
    },
    'screen': {
        'firstMessage': '',
        'system': 'You are Alex from Brightside Dental calling to confirm Sam\'s cleaning appointment on Tuesday. '
                  'An assistant will answer. Wait for the greeting, then say who you are and why you called. '
                  'Ask the assistant to have Sam call the office back today. When they confirm, say goodbye. '
                  'Speak in short sentences and wait for answers.',
        'maxDurationSeconds': 180,
    },
    'spam': {
        'firstMessage': '',
        'system': 'You are a telemarketer calling about a car\'s extended warranty. Wait for the greeting, then '
                  'give your pitch in two sentences and ask to speak with the owner. Keep pushing politely if refused.',
        'maxDurationSeconds': 120,
    },
}


def load_key() -> str:
    key = os.environ.get('VAPI_API')
    env = Path(__file__).resolve().parent.parent / '.env'
    if not key and env.is_file():
        for line in env.read_text().splitlines():
            if line.startswith('VAPI_API='):
                key = line.split('=', 1)[1].strip().strip('"\'')
    if not key:
        raise SystemExit('Set VAPI_API in the environment or the git-ignored .env file.')
    return key


def request(key: str, method: str, path: str, body: dict | None = None) -> dict:
    # Status polls tolerate transient network errors; creating a call does not retry.
    attempts = 1 if method == 'POST' else 5
    for attempt in range(attempts):
        try:
            return _request(key, method, path, body)
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == attempts - 1:
                raise SystemExit(f'Vapi {method} {path} failed: {error}')
            time.sleep(3)
    return {}


def _request(key: str, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        'Authorization': f'Bearer {key}', 'Content-Type': 'application/json',
        # Cloudflare in front of the API rejects urllib's default agent (error 1010).
        'User-Agent': 'android-ai-receptionist-test/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read() or b'{}')
    except urllib.error.HTTPError as error:
        raise SystemExit(f'Vapi {method} {path} failed: {error.code} {error.read().decode()[:400]}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--scenario', choices=sorted(SCENARIOS), required=True)
    parser.add_argument('--phone-number-id', required=True, help='Vapi phone number ID to call from')
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--to', help='E.164 number of the phone under test')
    target.add_argument('--to-file', type=Path, help='private file containing that number')
    parser.add_argument('--output', type=Path, required=True, help='directory for the report (outside the repo)')
    args = parser.parse_args()

    number = args.to or args.to_file.expanduser().read_text().strip()
    scenario = SCENARIOS[args.scenario]
    key = load_key()
    assistant = {
        'name': f'receptionist-test-{args.scenario}',
        'firstMessageMode': 'assistant-speaks-first' if scenario['firstMessage'] else 'assistant-waits-for-user',
        'model': {
            'provider': 'openai',
            'model': 'gpt-4o-mini',
            'temperature': 0.3,
            'messages': [{'role': 'system', 'content': scenario['system']}],
        },
        'transcriber': {'provider': 'deepgram', 'model': 'nova-2', 'language': 'en'},
        'maxDurationSeconds': scenario['maxDurationSeconds'],
        'silenceTimeoutSeconds': 45,
        'backgroundSound': 'off',
    }
    if scenario['firstMessage']:
        assistant['firstMessage'] = scenario['firstMessage']
        assistant['firstMessageInterruptionsEnabled'] = False

    args.output.mkdir(parents=True, exist_ok=True)
    started = time.time()
    call = request(key, 'POST', '/call', {
        'phoneNumberId': args.phone_number_id,
        'customer': {'number': number},
        'assistant': assistant,
    })
    call_id = call['id']
    print(f'call {call_id} status={call.get("status")}', flush=True)
    status = call.get('status')
    while status != 'ended' and time.time() - started < scenario['maxDurationSeconds'] + 120:
        time.sleep(4)
        call = request(key, 'GET', f'/call/{call_id}')
        if call.get('status') != status:
            status = call.get('status')
            print(f'  {time.time() - started:5.0f}s status={status}', flush=True)
    # Artifacts can arrive a few seconds after the call ends.
    for _ in range(6):
        if call.get('artifact', {}).get('transcript') or call.get('transcript'):
            break
        time.sleep(3)
        call = request(key, 'GET', f'/call/{call_id}')
    artifact = call.get('artifact') or {}
    report = {
        'scenario': args.scenario,
        'call_id': call_id,
        'status': call.get('status'),
        'ended_reason': call.get('endedReason'),
        'started_at': call.get('startedAt'),
        'ended_at': call.get('endedAt'),
        'transcript': artifact.get('transcript') or call.get('transcript'),
        'messages': [
            {k: m.get(k) for k in ('role', 'message', 'secondsFromStart', 'duration')}
            for m in (artifact.get('messages') or call.get('messages') or [])
            if m.get('role') in ('bot', 'user', 'assistant')
        ],
        'recording_url_present': bool(artifact.get('recordingUrl') or call.get('recordingUrl')),
    }
    (args.output / 'report.json').write_text(json.dumps(report, indent=2))
    print(f'ended_reason={report["ended_reason"]}')
    print(report['transcript'] or '(no transcript)')


if __name__ == '__main__':
    sys.exit(main())
