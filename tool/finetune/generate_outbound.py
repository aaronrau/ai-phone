"""Generate training dialogues for outbound calls ("call out").

Two decision points, each with its own option set:
  line     - what answered: person, voicemail, menu (phone tree), hold, other
  outbound - the other side's latest turn while the assistant pursues the
             owner's objective: offer_time, ask_time, confirm, ask_info,
             transfer, wrong_person, decline, goodbye, other

The other side's lines are written by a local Ollama model; the assistant's
lines are rebuilt from the app's fixed outbound phrasings (lib/src/outbound.dart).

Usage:
  python3 -I tool/finetune/generate_outbound.py --out <dir> [--per-scenario 6]
"""
import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dialogues import CONTEXT_SYSTEM, SLOT_SYSTEM, MAX_LINES, OWNERS, STYLES, ask, norm  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
OPTIONS = {
    'line': ['person', 'voicemail', 'menu', 'hold', 'other'],
    'outbound': ['offer_time', 'ask_time', 'confirm', 'ask_info', 'transfer', 'wrong_person', 'decline', 'goodbye',
                 'other'],
}
SLOTS = {'offer_time': ['day', 'time']}

OBJECTIVES = [
    'book a haircut on Friday afternoon', 'schedule a dental cleaning next week', 'book a table for two on Saturday '
    'evening', 'schedule an oil change this week', 'book a doctor appointment for a checkup', 'find a time for a '
    '30-minute call next week', 'set up a coffee meeting this week', 'reach the billing department about invoice '
    '1234', 'speak with the manager about a refund', 'reschedule the plumber visit to next Tuesday',
    'book a dog grooming appointment', 'confirm the delivery window for a couch',
]

LINE_SCENARIOS = [
    ('person_business', 'A receptionist at a business answers with the business name, their own name and how can I help.',
     'person'),
    ('person_personal', 'A person answers their own phone: hello, yeah, this is them speaking, or who is this.', 'person'),
    ('voicemail_personal', 'A personal voicemail greeting: you have reached a name, leave a message after the tone.',
     'voicemail'),
    ('voicemail_carrier', 'The carrier default voicemail: the person you are calling is not available, record your '
     'message at the tone, when finished hang up or press pound.', 'voicemail'),
    ('voicemail_business', 'A business after-hours voicemail with office hours and a request to leave a message.',
     'voicemail'),
    ('menu', 'An automated phone tree: thanks for calling, listen closely as our menu options have changed, for '
     'appointments press 1, for billing press 2, to speak to a representative press 0.', 'menu'),
    ('menu_speech', 'An automated assistant asking the caller to say in a few words why they are calling, or say '
     'representative.', 'menu'),
    ('hold', 'Hold messages: please hold, your call is important to us, all of our agents are busy, estimated wait '
     'time, or speech-to-text of hold music (fragments, repeated words, la la).', 'hold'),
    ('hold_then_person', 'After a hold message a person picks up: thanks for holding, this is a name, how can I help.',
     'hold then person'),
    ('transfer_ringing', 'Silence or a short ringing, then nothing intelligible.', 'other'),
]

TALK_SCENARIOS = [
    ('booking_offer', 'A scheduler offers specific days or times for the objective.', 'offer_time; then confirm'),
    ('booking_ask', 'A scheduler asks what day and time works for the owner.', 'ask_time; then offer_time or confirm'),
    ('booking_info', 'The other side asks for the owner\'s name, a phone number, date of birth, or details about the '
     'request before booking.', 'ask_info; then offer_time or confirm'),
    ('booking_full', 'Nothing is available, or they cannot help, or they say to call back later.', 'decline'),
    ('transfer', 'The person says they will transfer the call or asks the assistant to hold while they get someone.',
     'transfer'),
    ('wrong_department', 'The person says this is the wrong department, wrong person or wrong number for that.',
     'wrong_person'),
    ('meeting_contact', 'A colleague or friend is asked to find a time to meet; they propose times, ask about the '
     'owner\'s availability, or agree.', 'offer_time, ask_time or confirm'),
    ('message_delivery', 'The assistant asks the person to pass a message on; they agree, ask a question, or say the '
     'person is not there.', 'confirm, ask_info or wrong_person'),
    ('goodbye', 'The other side wraps up: anything else, thanks, bye.', 'goodbye'),
    ('offtopic', 'The other side asks whether this is a robot or says something unrelated or garbled.', 'other'),
]

RULES = """The AI caller's replies are fixed:
- after "person": introduces itself as the owner's AI assistant and states the objective
- after "menu": presses a key or says "representative"
- after "hold" or "transfer": stays silent and waits
- after "ask_time": says when the owner is free and asks if any of those work
- after "offer_time": accepts a time that fits the owner's calendar or suggests another
- after "ask_info": gives the owner's name, says the best number is this one, and repeats the objective
- after "wrong_person": asks to be transferred to someone who can help
- "confirm", "decline", "voicemail" and "goodbye" end the call.
Labels describe the OTHER side's latest turn: person = a live human answered; voicemail = an answering machine
greeting; menu = an automated phone tree or speech menu; hold = hold message or hold music; offer_time = proposes
specific day(s) or time(s); ask_time = asks when the owner is free; confirm = agrees or confirms the booking or that
they will pass the message; ask_info = asks for a name, number or details; transfer = will transfer or asks to hold;
wrong_person = wrong department or person; decline = cannot help or nothing available; goodbye = ending;
other = unclear or unrelated."""


def text_of(value) -> str:
    """Slot values sometimes come back as lists; speak them as one phrase."""
    if isinstance(value, list):
        return ' or '.join(str(v) for v in value)
    return str(value or '')


def ai_line(label: str, owner: str, objective: str, slots: dict) -> str:
    """The app's fixed outbound line after a decision (see lib/src/outbound.dart)."""
    return {
        'person': f"Hi, this is {owner}'s AI Assistant calling on behalf of {owner}. I'm calling to {objective}.",
        'menu': 'Representative.',
        'hold': '',
        'transfer': '',
        'ask_time': f'{owner} is free Thursday from ten AM to noon and Friday after two PM. Would any of those work?',
        'offer_time': f"{text_of(slots.get('day')).strip() or 'That'} {text_of(slots.get('time')).strip()} works for {owner}. "
                      'Could you book that, please?'.replace('  ', ' '),
        'ask_info': f"It's for {owner}, and the best number to reach {owner} is this one. I'm calling to {objective}.",
        'wrong_person': f'Could you transfer me to someone who can help me {objective}?',
        'other': 'Sorry, could you say that again?',
    }.get(label, '')


def build_prompt(name: str, description: str, guidance: str, step: str, objective: str, count: int, style: str) -> str:
    return (f'Write {count} different short phone call transcripts where an AI assistant calls someone on behalf of '
            f'its owner to {objective}. Scenario "{name}": {description} Expected labels: {guidance}.\n{RULES}\n'
            f'Allowed labels for the other side: {", ".join(OPTIONS[step])}' +
            (', and for later turns ' + ', '.join(OPTIONS['outbound']) if step == 'line' else '') +
            f'. Each transcript has 1 to 4 turns by the other side. Vary businesses, names, days and times; style of '
            f'the other side: {style}. For offer_time give slots day and time.\nReply as JSON: {{"dialogues": '
            f'[{{"turns": [{{"other": "...", "label": "...", "slots": {{}}}}]}}]}}')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--model', default='qwen3.8-64k:latest')
    parser.add_argument('--per-scenario', type=int, default=6)
    parser.add_argument('--repeats', type=int, default=2, help='objectives sampled per scenario')
    parser.add_argument('--seed', type=int, default=17)
    args = parser.parse_args()
    random.seed(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)
    held_out = set()
    path = REPO / 'test/fixtures/outbound_eval.jsonl'
    if path.exists():
        held_out = {norm(json.loads(l)['other']) for l in path.read_text().splitlines() if l.strip()}

    jobs = [(n, d, g, 'line') for n, d, g in LINE_SCENARIOS] + [(n, d, g, 'outbound') for n, d, g in TALK_SCENARIOS]
    jobs = [job + (random.choice(OBJECTIVES),) for job in jobs for _ in range(args.repeats)]
    raw_path = args.out / 'outbound.jsonl'
    done = set()
    if raw_path.exists():
        done = {json.loads(l)['scenario'] for l in raw_path.read_text().splitlines() if l.strip()}
    with raw_path.open('a') as raw:
        for index, (name, description, guidance, step, objective) in enumerate(jobs):
            key = f'{name}#{index}'
            if key in done:
                continue
            try:
                reply = json.loads(ask(args.model, build_prompt(name, description, guidance, step, objective,
                                                                 args.per_scenario, STYLES[index % len(STYLES)])))
            except Exception as error:
                print(f'{key} failed: {error}', flush=True)
                continue
            for dialogue in reply.get('dialogues', []):
                turns = [t for t in dialogue.get('turns', []) if isinstance(t, dict) and t.get('other')]
                if turns:
                    raw.write(json.dumps({'scenario': key, 'step': step, 'objective': objective, 'turns': turns}) + '\n')
            raw.flush()
            print(f'{index + 1}/{len(jobs)} {key}: {len(reply.get("dialogues", []))}', flush=True)

    examples, counts = [], {}
    for line in raw_path.read_text().splitlines():
        record = json.loads(line)
        owner = random.choice(OWNERS)
        lines = []
        step = record['step']
        for turn in record['turns']:
            text = str(turn['other']).strip()
            label = str(turn.get('label', '')).strip().lower()
            if label not in OPTIONS[step] or norm(text) in held_out:
                break
            lines.append(f'Other: {text}')
            options = OPTIONS[step][:]
            random.shuffle(options)
            user = 'Conversation:\n' + '\n'.join(lines[-MAX_LINES:]) + f'\nChoose one: {", ".join(options)}'
            examples.append({'kind': 'decision', 'messages': [
                {'role': 'system', 'content': CONTEXT_SYSTEM}, {'role': 'user', 'content': user},
                {'role': 'assistant', 'content': label}]})
            counts[label] = counts.get(label, 0) + 1
            slots = turn.get('slots') if isinstance(turn.get('slots'), dict) else {}
            if label in SLOTS:
                fields = SLOTS[label]
                examples.append({'kind': 'slots', 'messages': [
                    {'role': 'system', 'content': SLOT_SYSTEM},
                    {'role': 'user', 'content': f'Caller: "{text}"\nFields: {", ".join(fields)}'},
                    {'role': 'assistant', 'content': json.dumps({k: text_of(slots.get(k)) for k in fields})}]})
            if label in ('confirm', 'decline', 'voicemail', 'goodbye'):
                break
            reply = ai_line(label, owner, record['objective'], slots)
            if reply:
                lines.append(f'Assistant: {reply}')
            # After a live person answers, the conversation moves to the objective.
            if step == 'line' and label == 'person':
                step = 'outbound'
    random.shuffle(examples)
    (args.out / 'outbound_examples.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in examples))
    print(f'examples={len(examples)} labels={counts}')


if __name__ == '__main__':
    main()
