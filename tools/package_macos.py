#!/usr/bin/env python3
"""Package a completed Conductor app using macOS's built-in disk image tools."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


def info(message):
    print(f'[conductor] {message}', flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def app_manifest(app):
    """Compare payload bytes, executable permissions, and framework symlinks."""
    def scan_error(error):
        raise error

    result = {}
    for directory, dirs, files in os.walk(app, followlinks=False, onerror=scan_error):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entry = ('link', os.readlink(path))
            elif stat.S_ISREG(mode):
                entry = ('file', stat.S_IMODE(mode), sha256(path))
            elif stat.S_ISDIR(mode):
                entry = ('dir', stat.S_IMODE(mode))
            else:
                raise ValueError(f'Unsupported file in app bundle: {path}')
            result[path.relative_to(app).as_posix()] = entry
    return result


def package(app, output, release_tag):
    if sys.platform != 'darwin':
        raise ValueError('Disk image packaging requires macOS')
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError(f'Completed app bundle is missing: {app}')
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = metadata['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+-\d+\.\d+', release_tag):
        raise ValueError(f'Invalid built release tag: {release_tag}')
    if release_tag.split('-', 1)[0] != version:
        raise ValueError(f'Built release {release_tag} does not match app version {version}')
    executable_name = metadata['CFBundleExecutable']
    if Path(executable_name).name != executable_name:
        raise ValueError('Invalid app executable name')
    executable = app / 'Contents/MacOS' / executable_name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f'App executable is missing or not executable: {executable}')
    archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
    if set(archs) == {'arm64', 'x86_64'}:
        arch = 'universal'
    elif archs in [['arm64'], ['x86_64']]:
        arch = archs[0]
    else:
        raise ValueError(f'Unsupported app architectures: {archs}')
    name = f'Chromium-Conductor_{release_tag}_macos-{arch}.dmg'
    target = output / name
    checksum = output / f'{name}.sha256'
    if os.path.lexists(target) or os.path.lexists(checksum):
        raise ValueError(f'Package already exists in {output}; move the existing {name} '
                         'and its checksum before packaging this release again')
    output.mkdir(parents=True, exist_ok=True)

    # Newer macOS releases use diskutil image; retain hdiutil for older hosts.
    modern = subprocess.run(['/usr/sbin/diskutil', 'image', 'create', 'from', '--help'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    info(f'Packaging {release_tag} for {arch}')
    original = app_manifest(app)
    with tempfile.TemporaryDirectory(prefix='.conductor-package-', dir=output) as directory:
        work = Path(directory)
        payload = work / 'payload'
        payload.mkdir()
        copied_app = payload / app.name
        subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', str(app), str(copied_app)], check=True)
        if app_manifest(copied_app) != original:
            raise ValueError('App changed while staging; no package was published')
        (payload / 'Applications').symlink_to('/Applications', target_is_directory=True)
        image = work / name
        if modern:
            create = ['/usr/sbin/diskutil', 'image', 'create', 'from', '--format', 'UDZO',
                      '--volumeName', 'Chromium Conductor', str(payload), str(image)]
        else:
            create = ['/usr/bin/hdiutil', 'create', '-srcfolder', str(payload), '-volname',
                      'Chromium Conductor', '-fs', 'HFS+', '-format', 'UDZO', str(image)]
        info('Creating compressed disk image...')
        subprocess.run(create, check=True)
        subprocess.run(['/usr/bin/hdiutil', 'verify', str(image)], check=True)
        if image.stat().st_size >= 2 * 1024 ** 3:
            raise ValueError('Disk image exceeds GitHub Releases\' per-file limit of 2 GiB')

        # Inspect our newly created image read-only before publishing it.
        mount = work / 'mounted'
        mount.mkdir()
        if modern:
            attach = ['/usr/sbin/diskutil', 'image', 'attach', '--readOnly', '--nobrowse',
                      '--mountPoint', str(mount), str(image)]
        else:
            attach = ['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                      '-mountpoint', str(mount), str(image)]
        info('Checking packaged app and Applications shortcut...')
        try:
            subprocess.run(attach, check=True)
            if app_manifest(mount / app.name) != original:
                raise ValueError('Disk image does not contain the expected app')
            if os.readlink(mount / 'Applications') != '/Applications':
                raise ValueError('Disk image Applications shortcut is incorrect')
        finally:
            if mount.is_mount():
                subprocess.run(['/usr/sbin/diskutil', 'eject', str(mount)], check=True)
        if app_manifest(app) != original:
            raise ValueError('Original app changed during packaging; no package was published')
        staged_checksum = work / checksum.name
        staged_checksum.write_text(f'{sha256(image)}  {name}\n')

        # Hard links publish without overwriting an earlier release, even if
        # another packaging invocation reaches this point at the same time.
        published = []
        try:
            for source, destination in [(image, target), (staged_checksum, checksum)]:
                os.link(source, destination)
                published.append(destination)
        except BaseException:
            for destination in published:
                destination.unlink()
            raise
    info(f'Disk image: {target}')
    info(f'SHA-256: {checksum}')
    info('App content verified; existing signing preserved. Packaging does not sign or notarize.')
    return target, checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--release-tag', required=True)
    args = parser.parse_args()
    try:
        package(args.app.resolve(), args.output_dir.resolve(), args.release_tag)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'[conductor] error packaging disk image: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
