"""Copy the on-device models into the installed debug app's private storage.

Usage:
  python3 -B tool/provision_models.py --device <android-serial> \
      --gemma /path/to/gemma4-e2b.gguf --audio /path/to/audio/models

`--audio` is a directory containing any of `whisper/`, `vad/silero_vad.onnx`
and `pocket/` (the Pocket TTS voice bundle); only the
directories present are copied. Whisper files are named `<model>-encoder.int8.onnx`,
`<model>-decoder.int8.onnx` and `<model>-tokens.txt` (sherpa-onnx exports). Files are streamed
through `run-as`, so they are owned by the app and never placed in shared
storage. Install the debug APK first; uninstalling deletes the models.
"""
import argparse
import shlex
import subprocess
from pathlib import Path

PACKAGE = 'ai.local.receptionist'
STAGING = '/data/local/tmp/receptionist-models'


def adb(device: str, *args: str, capture: bool = False) -> str:
    result = subprocess.run(['adb', '-s', device, *args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout or ''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--device', required=True, help='adb serial of the target phone')
    parser.add_argument('--gemma', type=Path, help='Gemma GGUF to install (e.g. gemma4-e2b.gguf)')
    parser.add_argument('--audio', type=Path, help='directory with whisper/, vad/ and pocket/')
    parser.add_argument('--decision', type=Path, action='append', default=[],
                        help='small decision-model GGUF (repeatable), installed under models/decision/')
    parser.add_argument('--embedding', type=Path, help='sentence-embedding GGUF for intent detection, '
                        'installed under models/embedding/ (e.g. bge-small-en-v1.5-q8_0.gguf)')
    parser.add_argument('--stt', action='append', default=[], metavar='NAME=DIR',
                        help='speech model directory installed as models/NAME/ (e.g. parakeet-0.6b=<dir>)')
    parser.add_argument('--eval', type=Path, help='decision evaluation set (JSONL), installed as eval/decision_eval.jsonl')
    args = parser.parse_args()
    if 'package:' not in adb(args.device, 'shell', 'pm', 'path', PACKAGE, capture=True):
        raise SystemExit('Install the debug APK first.')

    files: dict[str, Path] = {}
    if args.gemma:
        if not args.gemma.is_file():
            raise SystemExit(f'Missing {args.gemma}')
        files[args.gemma.name] = args.gemma
    if args.audio:
        present = [d for d in ('whisper', 'vad', 'pocket') if (args.audio / d).is_dir()]
        if not present:
            raise SystemExit(f'{args.audio} contains none of whisper/, vad/ or pocket/')
        for directory in present:
            base = args.audio / directory
            for file in base.rglob('*'):
                if file.is_file() and not file.name.startswith('.'):
                    files[f'{directory}/{file.relative_to(base)}'] = file
    for model in args.decision:
        if not model.is_file():
            raise SystemExit(f'Missing {model}')
        files[f'decision/{model.name}'] = model
    if args.embedding:
        if not args.embedding.is_file():
            raise SystemExit(f'Missing {args.embedding}')
        files[f'embedding/{args.embedding.name}'] = args.embedding
    for spec in args.stt:
        name, _, directory = spec.partition('=')
        base = Path(directory)
        if not name or not base.is_dir():
            raise SystemExit(f'--stt expects NAME=DIR, got {spec}')
        for file in base.iterdir():
            if file.is_file() and file.suffix in ('.onnx', '.txt'):
                files[f'{name}/{file.name}'] = file
    extra_targets = {}
    if args.eval:
        extra_targets['eval/decision_eval.jsonl'] = args.eval
    if not files and not extra_targets:
        raise SystemExit('Nothing to provision; pass --gemma, --audio, --decision, --embedding, --stt and/or --eval.')

    # Replacing a memory-mapped model under a running process is unsafe.
    adb(args.device, 'shell', 'am', 'force-stop', PACKAGE)
    adb(args.device, 'shell', 'mkdir', '-p', STAGING)
    try:
        targets = {f'files/models/{name}': path for name, path in files.items()}
        targets.update({f'files/{name}': path for name, path in extra_targets.items()})
        for target, path in sorted(targets.items()):
            name = target.split('/', 1)[1]
            staged = f'{STAGING}/{name.replace("/", "__")}'
            adb(args.device, 'push', str(path), staged)
            parent = str(Path(target).parent)
            adb(args.device, 'shell', 'run-as', PACKAGE, 'mkdir', '-p', parent)
            adb(args.device, 'shell', f'cat {shlex.quote(staged)} | run-as {PACKAGE} sh -c '
                + shlex.quote(f'cat > {shlex.quote(target)}'))
            size = adb(args.device, 'shell', 'run-as', PACKAGE, 'stat', '-c', '%s', target, capture=True).strip()
            if int(size) != path.stat().st_size:
                raise SystemExit(f'Size mismatch for {name}')
            adb(args.device, 'shell', 'rm', '-f', staged)
            print(f'installed {name} ({path.stat().st_size} bytes)')
    finally:
        adb(args.device, 'shell', 'rm', '-rf', STAGING)
    print('Models installed in app-private storage.')


if __name__ == '__main__':
    main()
