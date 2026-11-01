"""Merge training data for the context-aware decision model (v2).

Combines multi-turn dialogue examples (generate_dialogues.py) with the first
round's single-turn utterances (generate_data.py) rendered in the same
conversation format. First-round "other" utterances are dropped: many of them
("who is this?", "hello?") should now be follow-up (clarify) turns.

Usage:
  python3 -I tool/finetune/merge_v2.py --v1 <data dir> --dialogues <dir> --out <dir>
"""
import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dialogues import CONTEXT_SYSTEM, OPTIONS, OWNERS, CALLER_NAMES, greeting  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--v1', type=Path, required=True)
    parser.add_argument('--dialogues', type=Path, required=True)
    parser.add_argument('--outbound', type=Path, help='directory with outbound_examples.jsonl (call-out dialogues)')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=5)
    args = parser.parse_args()
    random.seed(args.seed)
    examples = [json.loads(l) for l in (args.dialogues / 'dialogue_examples.jsonl').read_text().splitlines() if l.strip()]
    if args.outbound:
        outbound = [json.loads(l) for l in (args.outbound / 'outbound_examples.jsonl').read_text().splitlines() if l.strip()]
        examples += outbound * 3  # oversample: far fewer outbound dialogues than inbound
    added = 0
    for line in (args.v1 / 'utterances.jsonl').read_text().splitlines():
        u = json.loads(line)
        intent = u['intent']
        if intent == 'other':
            continue
        for workflow, options in OPTIONS.items():
            if intent not in options:
                continue  # e.g. identify/spam from a known contact is not a choice
            shuffled = options[:]
            random.shuffle(shuffled)
            lines = [f'Assistant: {greeting(workflow, random.choice(OWNERS), random.choice(CALLER_NAMES))}',
                     f'Caller: {u["text"]}']
            examples.append({'kind': 'decision', 'messages': [
                {'role': 'system', 'content': CONTEXT_SYSTEM},
                {'role': 'user', 'content': 'Conversation:\n' + '\n'.join(lines) + f'\nChoose one: {", ".join(shuffled)}'},
                {'role': 'assistant', 'content': intent}]})
            added += 1
    for line in (args.v1 / 'train.jsonl').read_text().splitlines():
        e = json.loads(line)
        if e['kind'] == 'slots':
            examples.append(e)
    random.shuffle(examples)
    split = max(80, len(examples) // 20)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'valid.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in examples[:split]))
    (args.out / 'train.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in examples[split:]))
    labels = {}
    for e in examples:
        if e['kind'] == 'decision':
            labels[e['messages'][-1]['content']] = labels.get(e['messages'][-1]['content'], 0) + 1
    print(f'examples={len(examples)} v1_converted={added} labels={labels}')


if __name__ == '__main__':
    main()
