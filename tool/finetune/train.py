"""Fine-tune the small decision model (default LFM2.5-350M) on the generated
receptionist turns, then export a Q8_0 GGUF for the phone.

Usage (in a venv with torch, transformers, gguf):
  python tool/finetune/train.py --data <dir> --out <dir> \
      --llama-cpp ~/.cache/android-ai-receptionist/llama.cpp

Training runs on the computer's GPU; the result runs offline on the phone.
"""
import argparse
import json
import math
import random
import subprocess
import sys
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, get_cosine_schedule_with_warmup


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def encode(tokenizer, messages: list[dict], max_length: int) -> tuple[list[int], list[int]]:
    """Token ids plus labels that train only on the final assistant answer."""
    prompt = tokenizer.apply_chat_template(messages[:-1], tokenize=False, add_generation_prompt=True)
    answer = messages[-1]['content'] + '<|im_end|>'
    prompt_ids = tokenizer(prompt, add_special_tokens=False)['input_ids']
    answer_ids = tokenizer(answer, add_special_tokens=False)['input_ids']
    ids = (prompt_ids + answer_ids)[:max_length]
    labels = ([-100] * len(prompt_ids) + answer_ids)[:max_length]
    return ids, labels


def batches(items: list, size: int, shuffle: bool):
    order = list(range(len(items)))
    if shuffle:
        random.shuffle(order)
    for i in range(0, len(order), size):
        yield [items[j] for j in order[i:i + size]]


def collate(batch, pad_id: int, device):
    longest = max(len(ids) for ids, _ in batch)
    input_ids = torch.full((len(batch), longest), pad_id, dtype=torch.long)
    labels = torch.full((len(batch), longest), -100, dtype=torch.long)
    mask = torch.zeros((len(batch), longest), dtype=torch.long)
    for row, (ids, lab) in enumerate(batch):
        input_ids[row, :len(ids)] = torch.tensor(ids)
        labels[row, :len(lab)] = torch.tensor(lab)
        mask[row, :len(ids)] = 1
    return input_ids.to(device), labels.to(device), mask.to(device)


@torch.no_grad()
def decision_accuracy(model, tokenizer, examples: list[dict], device) -> float:
    """Greedy first answer matches the label (decision examples only)."""
    model.eval()
    correct = total = 0
    for example in examples:
        if example['kind'] != 'decision':
            continue
        messages = example['messages']
        prompt = tokenizer.apply_chat_template(messages[:-1], tokenize=False, add_generation_prompt=True)
        ids = tokenizer(prompt, add_special_tokens=False, return_tensors='pt')['input_ids'].to(device)
        out = model.generate(ids, max_new_tokens=4, do_sample=False, pad_token_id=tokenizer.pad_token_id)
        text = tokenizer.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip().split()[:1]
        correct += int(bool(text) and text[0].strip('.,') == messages[-1]['content'])
        total += 1
    model.train()
    return correct / max(total, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--base', default='LiquidAI/LFM2.5-350M')
    parser.add_argument('--llama-cpp', type=Path, required=True, help='pinned llama.cpp checkout (for the converter)')
    parser.add_argument('--epochs', type=float, default=2.0)
    parser.add_argument('--lr', type=float, default=5e-5)
    parser.add_argument('--batch', type=int, default=16)
    parser.add_argument('--max-length', type=int, default=256)
    parser.add_argument('--seed', type=int, default=13)
    parser.add_argument('--name', default='receptionist-decision-v2-350m-q8_0.gguf', help='output GGUF file name')
    args = parser.parse_args()
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = 'cuda' if torch.cuda.is_available() else 'cpu'

    tokenizer = AutoTokenizer.from_pretrained(args.base)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(args.base, dtype=torch.bfloat16).to(device)
    model.train()

    train = load(args.data / 'train.jsonl')
    valid = load(args.data / 'valid.jsonl')
    encoded = [encode(tokenizer, e['messages'], args.max_length) for e in train]
    valid_encoded = [encode(tokenizer, e['messages'], args.max_length) for e in valid]
    print(f'train={len(train)} valid={len(valid)} device={device}', flush=True)
    print(f'baseline valid decision accuracy={decision_accuracy(model, tokenizer, valid[:200], device):.3f}', flush=True)

    steps = math.ceil(len(encoded) / args.batch * args.epochs)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    schedule = get_cosine_schedule_with_warmup(optimizer, max(10, steps // 20), steps)
    step = 0
    started = time.time()
    while step < steps:
        for batch in batches(encoded, args.batch, shuffle=True):
            input_ids, labels, mask = collate(batch, tokenizer.pad_token_id, device)
            loss = model(input_ids=input_ids, attention_mask=mask, labels=labels).loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            schedule.step()
            optimizer.zero_grad(set_to_none=True)
            step += 1
            if step % 50 == 0:
                print(f'step {step}/{steps} loss={loss.item():.4f} {time.time() - started:.0f}s', flush=True)
            if step >= steps:
                break

    with torch.no_grad():
        model.eval()
        losses = []
        for batch in batches(valid_encoded, args.batch, shuffle=False):
            input_ids, labels, mask = collate(batch, tokenizer.pad_token_id, device)
            losses.append(model(input_ids=input_ids, attention_mask=mask, labels=labels).loss.item())
    accuracy = decision_accuracy(model, tokenizer, valid, device)
    print(f'valid loss={sum(losses) / len(losses):.4f} decision accuracy={accuracy:.3f}', flush=True)

    hf_dir = args.out / 'hf'
    model.save_pretrained(hf_dir, safe_serialization=True)
    tokenizer.save_pretrained(hf_dir)
    gguf = args.out / args.name
    subprocess.run([sys.executable, str(args.llama_cpp / 'convert_hf_to_gguf.py'), str(hf_dir),
                    '--outtype', 'q8_0', '--outfile', str(gguf)], check=True)
    (args.out / 'training.json').write_text(json.dumps({
        'base': args.base, 'epochs': args.epochs, 'lr': args.lr, 'batch': args.batch, 'steps': steps,
        'train_examples': len(train), 'valid_examples': len(valid), 'valid_decision_accuracy': accuracy,
    }, indent=2))
    print(f'exported {gguf}')


if __name__ == '__main__':
    main()
