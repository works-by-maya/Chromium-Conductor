#!/usr/bin/env python3
"""Select an installed macOS SDK that the downloaded LLVM linker can use."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


def version(value):
    return tuple(int(part) for part in value.split('.'))


def sdk_version(path):
    with (path / 'System/Library/CoreServices/SystemVersion.plist').open('rb') as f:
        return plistlib.load(f)['ProductVersion']


def gn_version(path, name):
    match = re.search(rf'^\s*{name}\s*=\s*"([\d.]+)"', path.read_text(), re.M)
    if not match:
        raise ValueError(f'Cannot read {name} from {path}')
    return match.group(1)


def select_sdk(source, arch):
    minimum = version(gn_version(source / 'build/config/mac/mac_sdk_overrides.gni',
                                 'mac_sdk_min'))
    sdk_config = source / 'build/config/mac/mac_sdk.gni'
    official = gn_version(sdk_config, 'mac_sdk_official_version')
    deployment = gn_version(sdk_config, 'mac_deployment_target')
    explicit = os.environ.get('SDKROOT')
    active = Path(explicit or subprocess.check_output(
        ['xcrun', '--show-sdk-path'], text=True).strip()).resolve()
    candidates = [active]
    if not explicit:
        developer = Path(subprocess.check_output(
            ['xcode-select', '-p'], text=True).strip())
        installed = {}
        for directory in (developer / 'Platforms/MacOSX.platform/Developer/SDKs',
                          Path('/Library/Developer/CommandLineTools/SDKs')):
            if directory.is_dir():
                for path in directory.glob('MacOSX*.sdk'):
                    path = path.resolve()
                    try:
                        installed[path] = sdk_version(path)
                    except (OSError, KeyError, plistlib.InvalidFileException):
                        continue
        candidates += sorted(installed, key=lambda path: (
            installed[path] == official, version(installed[path])), reverse=True)

    clang = source / 'third_party/llvm-build/Release+Asserts/bin/clang'
    seen = set()
    with tempfile.TemporaryDirectory(prefix='conductor-sdk-') as temporary:
        probe = Path(temporary) / 'probe.c'
        probe.write_text('#include <stdio.h>\nint main(void) { puts("SDK probe"); return 0; }\n')
        for sdk in candidates:
            if sdk in seen:
                continue
            seen.add(sdk)
            value = sdk_version(sdk)
            if version(value) < minimum:
                print(f'[conductor] Skipping SDK {value}: below the release minimum',
                      file=sys.stderr)
                continue
            command = [str(clang), '-arch', arch, '-isysroot', str(sdk),
                       f'-mmacosx-version-min={deployment}', '-fuse-ld=lld', str(probe),
                       '-o', str(Path(temporary) / 'probe')]
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=30)
            if result.returncode == 0:
                print(f'[conductor] LLVM link check passed with macOS SDK {value}',
                      file=sys.stderr)
                return sdk
            print(f'[conductor] LLVM cannot link with macOS SDK {value}:',
                  file=sys.stderr)
            print('\n'.join(result.stderr.splitlines()[:5]), file=sys.stderr)
    raise ValueError('No compatible macOS SDK found. Install an SDK supported by '
                     'the downloaded LLVM linker, or set SDKROOT to one.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--arch', choices=('arm64', 'x86_64'), required=True)
    args = parser.parse_args()
    try:
        print(select_sdk(args.source_dir.resolve(), args.arch))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException,
            subprocess.SubprocessError) as error:
        print(f'[conductor] error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
