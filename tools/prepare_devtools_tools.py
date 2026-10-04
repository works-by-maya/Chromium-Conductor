#!/usr/bin/env python3
"""Restore the macOS DevTools tools using the checkout's package versions."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile


def prepare(source, cache):
    sys.path.insert(0, str(source / 'third_party/node'))
    import node

    node_binary = Path(node.GetBinaryPath())
    devtools = source / 'third_party/devtools-frontend/src'
    tsc_js = devtools / 'node_modules/typescript/lib/tsc.js'
    subprocess.run([str(node_binary), str(tsc_js), '--version'], check=True)

    version = json.loads((devtools / 'node_modules/esbuild/package.json').read_text())['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError(f'Unsupported esbuild package version: {version}')
    arch = {'arm64': 'arm64', 'x86_64': 'x64'}[platform.machine()]
    package = f'@esbuild/darwin-{arch}@{version}'
    directory = cache / f'esbuild-{version}-{arch}'
    binary = directory / 'esbuild'
    if not binary.exists():
        directory.mkdir(parents=True, exist_ok=True)
        npm = node_binary.parent / 'npm'
        result = subprocess.run(
            [str(node_binary), str(npm), 'pack', package, '--json', '--ignore-scripts',
             '--registry=https://registry.npmjs.org', '--userconfig=/dev/null',
             f'--cache={cache / "npm-cache"}', f'--pack-destination={directory}'],
            check=True, capture_output=True, text=True)
        info, = json.loads(result.stdout)
        archive = directory / Path(info['filename']).name
        integrity = 'sha512-' + base64.b64encode(
            hashlib.sha512(archive.read_bytes()).digest()).decode()
        if integrity != info['integrity']:
            raise ValueError('esbuild package integrity check failed')
        with tarfile.open(archive) as tar:
            member = tar.getmember('package/bin/esbuild')
            if not member.isfile():
                raise ValueError('esbuild package does not contain a regular binary')
            with tar.extractfile(member) as extracted:
                binary.write_bytes(extracted.read())
        binary.chmod(0o755)
        (directory / 'package-metadata.json').write_text(json.dumps(info, indent=2) + '\n')

    actual = subprocess.check_output([str(binary), '--version'], text=True).strip()
    if actual != version:
        raise ValueError(f'esbuild version mismatch: expected {version}, got {actual}')

    # The direct GN actions and Python TypeScript helper share this launcher.
    launcher = devtools / 'third_party/typescript/tsc'
    contents = '#!/bin/sh\nexec ' + shlex.quote(str(node_binary)) + ' ' + shlex.quote(str(tsc_js)) + ' "$@"\n'
    launcher.parent.mkdir(parents=True, exist_ok=True)
    if not launcher.exists() or launcher.read_text() != contents:
        launcher.write_text(contents)
    launcher.chmod(0o755)

    destination = devtools / 'third_party/esbuild/esbuild'
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or destination.read_bytes() != binary.read_bytes():
        shutil.copy2(binary, destination)
    print(f'[conductor] DevTools esbuild {actual} and bundled TypeScript are ready')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.source_dir.resolve(), args.cache_dir.resolve())
    except (OSError, ValueError, KeyError, tarfile.TarError,
            subprocess.SubprocessError) as error:
        print(f'[conductor] error preparing DevTools tools: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
