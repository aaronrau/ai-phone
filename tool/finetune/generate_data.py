"""Generate synthetic training data for the small decision model.

Uses a local Ollama model on the computer (no cloud) to write varied caller
utterances for each intent, then renders them into the exact compact prompts
the app uses (lib/src/decision.dart, DecisionStyle.tuned). Utterances that
match the held-out evaluation set are dropped.

Usage:
  python3 -I tool/finetune/generate_data.py --out <dir> [--per-batch 25] [--batches 10]
"""
import argparse
import json
import random
import re
import urllib.request
from pathlib import Path

OLLAMA = 'http://127.0.0.1:11434/api/generate'
REPO = Path(__file__).resolve().parents[2]

INTENTS = {
    'identify': ('The caller says who they are and/or why they are calling (a person, business, office, school, '
                 'delivery, doctor, contractor, colleague, relative). Include their name or company when natural.',
                 {'name': "caller's name or company ('' if not said)", 'reason': "why they call ('' if not said)"}),
    'spam': ('A spam, scam, telemarketing, robocall, survey, prize, warranty, loan, debt, crypto, insurance, '
             'solar or other unsolicited sales call opening line.', {}),
    'message': ('The caller asks to leave a message, asks for a call back, or dictates something to pass on '
                'to the owner.', {'message': "the message to pass on, in their words ('' if none yet)"}),
    'availability': ('The caller asks when the owner is free, wants to meet or schedule, or asks about a specific '
                     'day or time.', {'day': "day mentioned ('' if none)", 'time': "time mentioned ('' if none)"}),
    'goodbye': ('The caller ends the call: goodbye, thanks that is all, never mind, wrong number, will call later.', {}),
    'other': ('Off-script turns: questions to the assistant (are you a robot, who is this, can I talk to a human), '
              'small talk, asking for personal info about the owner, confusion (hello? can you hear me?), '
              'emergencies, or unrelated remarks.', {}),
}

STYLES = [
    'polite and complete sentences',
    'casual and short, like real speech',
    'messy speech-to-text output: lowercase, no punctuation, a few misheard words, filler words like uh and um',
    'very short, 2 to 6 words',
    'long and rambling, two or three sentences',
    'direct and businesslike',
]

STEPS = {
    'screen_open': (['identify', 'spam', 'message', 'goodbye'],
                    ['May I ask who is calling and what it is about?', 'Who may I say is calling?',
                     "Hello, you've reached {owner}'s assistant. May I ask who is calling?",
                     'Can I ask what this is regarding?']),
    'known_open': (['availability', 'message', 'goodbye'],
                   ["{owner} can't come to the phone right now. How can I help?", 'How can I help you today?',
                    "Hi! {owner} is busy at the moment. What can I do for you?"]),
    'anything_else': (['goodbye', 'message', 'availability'],
                      ['Is there anything else I can help you with?', 'Anything else?',
                       "I'll pass that on. Is there anything else?"]),
}

OWNERS = ['Sam', 'Jordan', 'Alex', 'Dr. Patel', 'Maria', 'Chris', 'Taylor', 'Ms. Nguyen', 'Robert', 'Aisha']

DECISION_SYSTEM = "Classify the caller's turn in a phone call. Answer with one option word."
SLOT_SYSTEM = "Extract details from the caller's words as JSON. Copy their words; use \"\" when not said."


def decision_messages(assistant_said: str, caller: str, labels: list[str], answer: str) -> list[dict]:
    user = f'Assistant: "{assistant_said}"\nCaller: "{caller}"\nChoose one: {", ".join(labels)}'
    return [{'role': 'system', 'content': DECISION_SYSTEM}, {'role': 'user', 'content': user},
            {'role': 'assistant', 'content': answer}]


def slot_messages(caller: str, slots: dict, values: dict) -> list[dict]:
    user = f'Caller: "{caller}"\nFields: {", ".join(slots)}'
    answer = json.dumps({k: str(values.get(k, '') or '') for k in slots}, ensure_ascii=False)
    return [{'role': 'system', 'content': SLOT_SYSTEM}, {'role': 'user', 'content': user},
            {'role': 'assistant', 'content': answer}]


def ask(model: str, prompt: str) -> str:
    body = json.dumps({'model': model, 'prompt': prompt, 'stream': False, 'think': False, 'format': 'json',
                       'options': {'temperature': 1.0, 'num_predict': 3000}}).encode()
    request = urllib.request.Request(OLLAMA, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.loads(response.read())['response']


def norm(text: str) -> str:
    return re.sub(r'[^a-z0-9 ]', '', text.lower()).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--model', default='qwen3.8-64k:latest')
    parser.add_argument('--per-batch', type=int, default=25)
    parser.add_argument('--batches', type=int, default=10, help='batches per intent (styles rotate)')
    parser.add_argument('--seed', type=int, default=7)
    args = parser.parse_args()
    random.seed(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)
    held_out = {norm(json.loads(line)['caller'])
                for line in (REPO / 'test/fixtures/decision_eval.jsonl').read_text().splitlines() if line.strip()}

    raw_path = args.out / 'utterances.jsonl'
    utterances = []
    if raw_path.exists():
        utterances = [json.loads(line) for line in raw_path.read_text().splitlines() if line.strip()]
    done = {(u['intent'], u['batch']) for u in utterances}
    with raw_path.open('a') as raw:
        for intent, (description, slots) in INTENTS.items():
            for batch in range(args.batches):
                if (intent, batch) in done:
                    continue
                style = STYLES[batch % len(STYLES)]
                slot_text = ''
                if slots:
                    fields = ', '.join(f'"{k}": {v}' for k, v in slots.items())
                    slot_text = f' For each item also give "slots": {{{fields}}}.'
                prompt = (f'Write {args.per_batch} different things a caller might say to a phone receptionist. '
                          f'Situation: {description} Style: {style}. Vary names, businesses, topics, days and '
                          f'wording; no two alike.{slot_text} Reply as JSON: {{"items": [{{"text": "..."'
                          f'{", \"slots\": {...}" if slots else ""}}}]}}')
                try:
                    items = json.loads(ask(args.model, prompt)).get('items', [])
                except Exception as error:  # keep going; a rerun resumes
                    print(f'{intent} batch {batch} failed: {error}')
                    continue
                for item in items:
                    text = str(item.get('text', '')).strip() if isinstance(item, dict) else str(item).strip()
                    if not text or norm(text) in held_out:
                        continue
                    record = {'intent': intent, 'batch': batch, 'text': text,
                              'slots': item.get('slots', {}) if isinstance(item, dict) else {}}
                    utterances.append(record)
                    raw.write(json.dumps(record, ensure_ascii=False) + '\n')
                raw.flush()
                print(f'{intent} batch {batch}: {len(items)} items ({style})', flush=True)

    # Render training examples: each utterance at every step, mapped to that
    # step's option list ('other' when its intent is not offered there).
    seen = set()
    examples = []
    for u in utterances:
        key = (u['intent'], norm(u['text']))
        if key in seen:
            continue
        seen.add(key)
        for step, (labels, phrasings) in STEPS.items():
            options = labels + ['other']
            answer = u['intent'] if u['intent'] in labels else 'other'
            said = random.choice(phrasings).format(owner=random.choice(OWNERS))
            shuffled = labels[:]
            random.shuffle(shuffled)  # option order must not matter
            examples.append({'kind': 'decision', 'step': step,
                             'messages': decision_messages(said, u['text'], shuffled + ['other'], answer)})
        slots = INTENTS[u['intent']][1]
        if slots and isinstance(u.get('slots'), dict):
            examples.append({'kind': 'slots', 'messages': slot_messages(u['text'], slots, u['slots'])})
    random.shuffle(examples)
    split = max(50, len(examples) // 20)
    (args.out / 'valid.jsonl').write_text(''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in examples[:split]))
    (args.out / 'train.jsonl').write_text(''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in examples[split:]))
    counts = {}
    for e in examples:
        k = e['kind'] if e['kind'] == 'slots' else e['messages'][-1]['content']
        counts[k] = counts.get(k, 0) + 1
    print(f'utterances={len(seen)} examples={len(examples)} counts={counts}')


if __name__ == '__main__':
    main()
