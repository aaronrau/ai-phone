"""Generate multi-turn training dialogues for the context-aware decision model.

A local Ollama model writes the caller's side of short conversations for every
scenario in scenarios.py and labels the receptionist's correct action after
each caller turn. The receptionist's lines are then rebuilt from the app's
fixed phrasings, so training context matches what the app says at runtime.

Usage:
  python3 -I tool/finetune/generate_dialogues.py --out <dir> [--per-scenario 6]
"""
import argparse
import json
import random
import re
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scenarios import AMBIGUOUS, KNOWN, LEGIT, SCAMS  # noqa: E402

OLLAMA = 'http://127.0.0.1:11434/api/generate'
REPO = Path(__file__).resolve().parents[2]

# Must match lib/src/decision.dart (renderContextDecisionPrompt) exactly.
CONTEXT_SYSTEM = "Decide the receptionist's next action from the phone conversation. Answer with one option word."
SLOT_SYSTEM = "Extract details from the caller's words as JSON. Copy their words; use \"\" when not said."
OPTIONS = {
    'screen': ['identify', 'message', 'clarify', 'spam', 'goodbye', 'other'],
    'known': ['availability', 'message', 'clarify', 'goodbye', 'other'],
}
SLOTS = {
    'identify': ['name', 'reason'],
    'message': ['message'],
    'availability': ['day', 'time'],
}
MAX_LINES = 7
OWNERS = ['Sam', 'Jordan', 'Alex', 'Maria', 'Chris', 'Taylor', 'Robert', 'Aisha', 'Dana', 'Lee']
CALLER_NAMES = ['Mom', 'Chris', 'Pat', 'Jamie', 'Morgan', 'Uncle Ray', 'Kim', 'Devon']
STYLES = ['natural spoken English', 'messy speech-to-text: lowercase, no punctuation, filler words, a misheard word',
          'short and terse', 'chatty and rambling', 'polite and formal', 'pushy and impatient']


def assistant_reply(label: str, slots: dict, owner: str, clarifies: int) -> str:
    """The app's fixed line after a decision (see lib/src/tiered.dart)."""
    if label == 'clarify':
        return (f"{owner} isn't available right now. May I ask who's calling and what it's regarding?"
                if clarifies == 1 else f'Could you tell me a bit more about what you need from {owner}?')
    if label == 'identify':
        name = (slots.get('name') or '').split(' ')[0]
        return f"Thanks{', ' + name if name else ''}. {owner} isn't available right now. Would you like to leave a message?"
    if label == 'message':
        if len((slots.get('message') or '').split()) < 4:
            return f'Of course. What would you like me to tell {owner}?'
        return f"Got it, I'll pass that on to {owner}. Is there anything else I can help you with?"
    if label == 'availability':
        return f'{owner} is free tomorrow from ten AM to two PM. Would you like to leave a message for {owner}?'
    if label == 'goodbye':
        return 'Thanks for calling. Goodbye.'
    return f'I can take a message for {owner}. What would you like me to pass on?'


def greeting(workflow: str, owner: str, caller: str) -> str:
    if workflow == 'known':
        return f"Hi {caller}, you've reached {owner}'s AI Assistant. How can I help?"
    return f"Hi, you've reached {owner}'s AI Assistant. How can I help?"


def ask(model: str, prompt: str) -> str:
    body = json.dumps({'model': model, 'prompt': prompt, 'stream': False, 'think': False, 'format': 'json',
                       'options': {'temperature': 1.0, 'num_predict': 4000}}).encode()
    request = urllib.request.Request(OLLAMA, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=900) as response:
        return json.loads(response.read())['response']


RULES = """The receptionist's replies are fixed:
- after "clarify": asks who is calling and what it is regarding (then, a second time, asks for more detail)
- after "identify": thanks them and offers to take a message
- after "message": asks what to pass on, or confirms it will pass it on and asks if there is anything else
- after "availability": says when the owner is free and offers to take a message
- after "other": offers to take a message
- "spam" and "goodbye" end the call.
Labels (the receptionist's correct action after that caller turn):
clarify = intent or objective not clear yet; identify = caller has said who they are and a legitimate reason;
message = wants to leave or is dictating a message or call back; availability = asks when the owner is free
(known callers only); spam = selling something, asking for money or payment, asking the receptionist to do
something (press a key, read a code, install, confirm personal details), threats, prizes, impersonation with demands;
goodbye = ending the call; other = off-topic question or small talk for the assistant."""


def build_prompt(kind: str, name: str, description: str, guidance: str, workflow: str, count: int, style: str) -> str:
    labels = ', '.join(OPTIONS[workflow])
    who = 'a friend or relative the owner knows' if workflow == 'known' else 'an unknown caller'
    return (f'Write {count} different short phone conversations between {who} and an AI receptionist answering for '
            f'the owner. Scenario ({kind} "{name}"): {description} Expected handling: {guidance}.\n{RULES}\n'
            f'Allowed labels: {labels}. Each conversation has 1 to 4 caller turns and stops after a spam or goodbye '
            f'label. Vary names, companies, amounts and wording; caller style: {style}. Never reuse exact sentences. '
            f'For identify give slots name and reason; for message give slot message (their words, "" if none yet); '
            f'for availability give slots day and time.\nReply as JSON: {{"dialogues": [{{"turns": [{{"caller": "...", '
            f'"label": "...", "slots": {{}}}}]}}]}}')


def norm(text: str) -> str:
    return re.sub(r'[^a-z0-9 ]', '', text.lower()).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--model', default='qwen3.8-64k:latest')
    parser.add_argument('--per-scenario', type=int, default=6)
    parser.add_argument('--seed', type=int, default=11)
    args = parser.parse_args()
    random.seed(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)
    held_out = set()
    for fixture in ('decision_eval.jsonl', 'decision_eval_v2.jsonl'):
        path = REPO / 'test/fixtures' / fixture
        if path.exists():
            held_out |= {norm(json.loads(l)['caller']) for l in path.read_text().splitlines() if l.strip()}

    jobs = ([('scam', n, d, g, 'screen') for n, d, g in SCAMS] +
            [('legitimate call', n, d, g, 'screen') for n, d, g in LEGIT] +
            [('ambiguous opening', n, d, 'clarify first; then identify if legitimate, spam if it turns into a scam, '
              'or message', 'screen') for n, d in AMBIGUOUS] +
            [('known caller', n, d, g, 'known') for n, d, g in KNOWN for _ in range(2)])
    raw_path = args.out / 'dialogues.jsonl'
    done = {}
    if raw_path.exists():
        for line in raw_path.read_text().splitlines():
            if line.strip():
                record = json.loads(line)
                done[record['scenario']] = done.get(record['scenario'], 0) + 1
    with raw_path.open('a') as raw:
        for index, (kind, name, description, guidance, workflow) in enumerate(jobs):
            key = f'{name}#{index}'
            if done.get(key):
                continue
            style = STYLES[index % len(STYLES)]
            try:
                reply = json.loads(ask(args.model, build_prompt(kind, name, description, guidance, workflow,
                                                                 args.per_scenario, style)))
            except Exception as error:  # rerun resumes
                print(f'{key} failed: {error}', flush=True)
                continue
            for dialogue in reply.get('dialogues', []):
                turns = [t for t in dialogue.get('turns', []) if isinstance(t, dict) and t.get('caller')]
                if not turns:
                    continue
                raw.write(json.dumps({'scenario': key, 'kind': kind, 'workflow': workflow, 'turns': turns}) + '\n')
            raw.flush()
            print(f'{index + 1}/{len(jobs)} {key}: {len(reply.get("dialogues", []))} dialogues', flush=True)

    examples, counts, dropped = [], {}, 0
    for line in raw_path.read_text().splitlines():
        record = json.loads(line)
        workflow = record['workflow']
        options = OPTIONS[workflow]
        owner = random.choice(OWNERS)
        lines = [f'Assistant: {greeting(workflow, owner, random.choice(CALLER_NAMES))}']
        clarifies = 0
        for turn in record['turns']:
            caller = str(turn['caller']).strip()
            label = str(turn.get('label', '')).strip().lower()
            if label not in options or norm(caller) in held_out:
                dropped += 1
                break
            lines.append(f'Caller: {caller}')
            shuffled = options[:]
            random.shuffle(shuffled)
            user = 'Conversation:\n' + '\n'.join(lines[-MAX_LINES:]) + f'\nChoose one: {", ".join(shuffled)}'
            examples.append({'kind': 'decision', 'messages': [
                {'role': 'system', 'content': CONTEXT_SYSTEM}, {'role': 'user', 'content': user},
                {'role': 'assistant', 'content': label}]})
            counts[label] = counts.get(label, 0) + 1
            slots = turn.get('slots') if isinstance(turn.get('slots'), dict) else {}
            if label in SLOTS:
                fields = SLOTS[label]
                answer = json.dumps({k: (' or '.join(map(str, slots[k])) if isinstance(slots.get(k), list)
                                         else str(slots.get(k, '') or '')) for k in fields}, ensure_ascii=False)
                examples.append({'kind': 'slots', 'messages': [
                    {'role': 'system', 'content': SLOT_SYSTEM},
                    {'role': 'user', 'content': f'Caller: "{caller}"\nFields: {", ".join(fields)}'},
                    {'role': 'assistant', 'content': answer}]})
            if label in ('spam', 'goodbye'):
                break
            if label == 'clarify':
                clarifies += 1
            lines.append(f'Assistant: {assistant_reply(label, slots, owner, clarifies)}')
    random.shuffle(examples)
    (args.out / 'dialogue_examples.jsonl').write_text(
        ''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in examples))
    print(f'examples={len(examples)} dropped_dialogues={dropped} labels={counts}')


if __name__ == '__main__':
    main()
