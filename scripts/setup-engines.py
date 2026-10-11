#!/usr/bin/env python3
"""Install pinned Glulxe/RemGlk, python-chess and the maintained example in a cache."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[1]
SOURCES = json.loads((ROOT / 'scripts/engine-sources.json').read_text())


def download(cache, name):
    source = SOURCES[name]
    version = source.get('revision', source.get('version'))
    archive = cache / f'{name}-{version}.tar.gz'
    if not archive.exists():
        for existing in cache.glob('*.tar.gz'):
            if hashlib.sha256(existing.read_bytes()).hexdigest() == source['sha256']:
                return existing
        pending = archive.with_suffix('.partial')
        with urllib.request.urlopen(source['url'], timeout=60) as response, pending.open('wb') as out:
            shutil.copyfileobj(response, out)
        pending.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != source['sha256']:
        raise ValueError(f'Checksum mismatch: remove {archive} and retry')
    return archive


def unpack(archive, target, digest):
    marker = target / '.source-sha256'
    if marker.is_file() and marker.read_text().strip() == digest:
        return
    with tempfile.TemporaryDirectory(dir=target.parent) as temporary:
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                destination = (Path(temporary) / member.name).resolve()
                if (not destination.is_relative_to(Path(temporary).resolve())
                        or not (member.isfile() or member.isdir())):
                    raise ValueError(f'Unsafe archive member: {member.name}')
            bundle.extractall(temporary)
        entries = list(Path(temporary).iterdir())
        if len(entries) != 1 or not entries[0].is_dir():
            raise ValueError(f'Archive must contain one source directory: {archive}')
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(entries[0]), target)
    marker.write_text(digest + '\n')


def paths(cache):
    return {'python': str(cache / 'python/bin/python3'),
            'glulxe': str(cache / 'bin/glulxe'),
            'stockfish': str(cache / 'bin/stockfish'),
            'story': str(cache / 'last-beacon.ulx')}


def link(executable, destination):
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        raise ValueError(f'Refusing to replace non-symlink executable: {destination}')
    destination.symlink_to(Path(executable).resolve())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path,
                        default=Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines')
    parser.add_argument('--stockfish', type=Path, help='Use an existing Stockfish executable (required outside macOS when absent from PATH).')
    parser.add_argument('--check', action='store_true', help='Check installed executable paths without downloading or modifying files.')
    parser.add_argument('--manifest', action='store_true', help='Print pinned upstream URLs and checksums without installing.')
    args = parser.parse_args()
    if args.manifest:
        print(json.dumps(SOURCES, indent=2)); return 0
    cache = args.cache.expanduser().resolve()
    result = paths(cache)
    if args.check:
        missing = [name for name, path in result.items()
                   if not (Path(path).is_file() and (name == 'story' or os.access(path, os.X_OK)))]
        print(json.dumps({'paths': result, 'missing': missing}, indent=2))
        return int(bool(missing))
    cache.mkdir(parents=True, exist_ok=True)
    source_root = cache / 'sources'; source_root.mkdir(exist_ok=True)
    binary_root = cache / 'bin'; binary_root.mkdir(exist_ok=True)
    for name in ('remglk', 'glulxe', 'inform6', 'inform6lib'):
        unpack(download(cache, name), source_root / name, SOURCES[name]['sha256'])
    subprocess.run(['make', '-C', str(source_root / 'remglk'),
                    'OPTIONS=-O2 -Wall -Wno-unused'], check=True)
    os_flag = '-DOS_MAC' if sys.platform == 'darwin' else '-DOS_UNIX'
    subprocess.run(['make', '-C', str(source_root / 'glulxe'), 'GLKINCLUDEDIR=../remglk',
                    'GLKLIBDIR=../remglk', 'GLKMAKEFILE=Make.remglk',
                    f'OPTIONS=-O2 -Wall -Wno-unused {os_flag}'], check=True)
    compiler = source_root / 'inform6/inform'
    subprocess.run(['cc', '-O2', '-o', str(compiler),
                    *map(str, sorted((source_root / 'inform6').glob('*.c')))], check=True)
    subprocess.run([str(compiler), '-G', f'+include_path={source_root / "inform6lib"}',
                    str(ROOT / 'examples/last-beacon.inf'), result['story']], check=True)
    link(source_root / 'glulxe/glulxe', binary_root / 'glulxe')
    python = Path(result['python'])
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(cache / 'python')
    requirement = cache / 'chess-requirements.txt'
    requirement.write_text(f'chess=={SOURCES["chess"]["version"]} --hash=sha256:{SOURCES["chess"]["sha256"]}\n')
    subprocess.run([str(python), '-m', 'pip', 'install', '--require-hashes', '-r', str(requirement)], check=True)
    stockfish = args.stockfish or shutil.which('stockfish')
    if not stockfish and sys.platform == 'darwin':
        target = cache / 'stockfish'
        unpack(download(cache, 'stockfish-macos'), target, SOURCES['stockfish-macos']['sha256'])
        stockfish = target / 'stockfish-macos-universal'
    if not stockfish or not os.access(stockfish, os.X_OK):
        raise ValueError('Install Stockfish and pass --stockfish /path/to/stockfish, then rerun')
    link(stockfish, binary_root / 'stockfish')
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as failure:
        print(f'Engine setup failed: {failure}', file=sys.stderr)
        sys.exit(1)
