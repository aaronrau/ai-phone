"""Provision pinned native build dependencies outside Git.

Creates, under $RECEPTIONIST_NATIVE_CACHE (default ~/.cache/android-ai-receptionist):
  llama.cpp/            pinned llama.cpp source used by native/CMakeLists.txt
  jniLibs/arm64-v8a/    sherpa-onnx JNI + ONNX Runtime from the official release
These downloads happen on the computer at build time only; the app itself
never uses the network.
"""
import hashlib
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

LLAMA_COMMIT = 'ea0c4c2c85fb183ec0fbd30a1af4e4275a18a064'
SHERPA_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-android.tar.bz2'
SHERPA_SHA256 = '635eee004bf12d5881789876ea01964a6ef10dc74ccf317271ba9388d8718a84'
SHERPA_LIBS = ('libsherpa-onnx-jni.so', 'libsherpa-onnx-c-api.so', 'libonnxruntime.so')


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1 << 22), b''):
            value.update(part)
    return value.hexdigest()


def main() -> None:
    cache = Path(os.environ.get('RECEPTIONIST_NATIVE_CACHE', Path.home() / '.cache/android-ai-receptionist'))
    cache.mkdir(parents=True, exist_ok=True)

    llama = cache / 'llama.cpp'
    if not llama.exists():
        subprocess.run(['git', 'clone', '--no-checkout', '--filter=blob:none',
                        'https://github.com/ggml-org/llama.cpp.git', str(llama)], check=True)
        subprocess.run(['git', '-C', str(llama), 'checkout', LLAMA_COMMIT], check=True)
    head = subprocess.check_output(['git', '-C', str(llama), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(llama), 'status', '--porcelain'], text=True)
    if head != LLAMA_COMMIT or dirty:
        raise SystemExit(f'{llama} must be a clean checkout of {LLAMA_COMMIT}')

    archive = cache / 'dl' / 'sherpa-android.tar.bz2'
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(SHERPA_URL, archive)
    if digest(archive) != SHERPA_SHA256:
        raise SystemExit('sherpa-onnx archive hash mismatch')
    target = cache / 'jniLibs' / 'arm64-v8a'
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:bz2') as bundle:
        for name in SHERPA_LIBS:
            member = bundle.getmember(f'./jniLibs/arm64-v8a/{name}')
            with bundle.extractfile(member) as source, (target / name).open('wb') as out:
                shutil.copyfileobj(source, out)
    print(f'Native dependencies ready in {cache}')


if __name__ == '__main__':
    main()
