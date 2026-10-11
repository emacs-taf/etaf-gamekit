#!/usr/bin/env python3
"""Run a chess or Glulx engine using the ETAF game JSON-lines protocol."""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

MAX_MESSAGE = 1024 * 1024


def atomic_json(filename, value):
    destination = Path(filename).expanduser().resolve()
    fd, temporary = tempfile.mkstemp(prefix='.etaf-gamekit-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.write('\n')
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_snapshot(filename, kind):
    raw = Path(filename).expanduser().read_bytes()
    if len(raw) > 8 * MAX_MESSAGE:
        raise ValueError('Snapshot exceeds 8 MiB')
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get('format') != 'etaf-gamekit/1' or data.get('kind') != kind:
        raise ValueError('Snapshot belongs to a different adapter or format')
    return data


class Chess:
    capabilities = ['move', 'engine', 'undo', 'restart', 'save', 'load']

    def __init__(self, args):
        import chess
        import chess.engine
        self.chess = chess
        self.initial = args.fen or chess.STARTING_FEN
        self.board = chess.Board(self.initial)
        if not self.board.is_valid():
            raise ValueError('The initial FEN is not a valid chess position')
        self.stockfish = args.stockfish
        self.engine = None

    def view(self):
        board = self.board
        outcome = board.outcome()
        if outcome:
            status = f'{outcome.result()} — {outcome.termination.name.lower().replace("_", " ")}'
        else:
            status = ('White' if board.turn else 'Black') + ' to move'
            if board.is_check():
                status += ' — check'
        return {'kind': 'chess', 'title': 'Chess', 'status': status,
                'fen': board.fen(), 'board': str(board).splitlines(),
                'legal': [move.uci() for move in board.legal_moves],
                'moves': [move.uci() for move in board.move_stack],
                'last_move': board.peek().uci() if board.move_stack else None,
                'finished': outcome is not None}

    def act(self, operation, payload):
        if operation == 'start':
            return
        if operation == 'move':
            # python-chess is the only authority for legality, promotions and state.
            if self.board.is_game_over():
                raise ValueError('The game has finished')
            move = self.chess.Move.from_uci(payload['move'])
            if move not in self.board.legal_moves:
                raise ValueError(f'Illegal move: {payload["move"]}')
            self.board.push(move)
        elif operation == 'engine':
            if self.board.is_game_over():
                raise ValueError('The game has finished')
            if self.engine is None:
                self.engine = self.chess.engine.SimpleEngine.popen_uci(self.stockfish, timeout=10)
                self.engine.configure({'Threads': 1, 'Hash': 16})
            answer = self.engine.play(self.board, self.chess.engine.Limit(time=0.1))
            if answer.move is None:
                raise ValueError('The engine returned no move')
            self.board.push(answer.move)
        elif operation == 'undo':
            if not self.board.move_stack:
                raise ValueError('There is no move to undo')
            self.board.pop()
        elif operation == 'restart':
            self.board = self.chess.Board(self.initial)
        elif operation == 'save':
            atomic_json(payload['path'], {'format': 'etaf-gamekit/1', 'kind': 'chess',
                        'initial': self.initial, 'moves': [m.uci() for m in self.board.move_stack]})
        elif operation == 'load':
            data = read_snapshot(payload['path'], 'chess')
            restored = self.chess.Board(data['initial'])
            if not restored.is_valid():
                raise ValueError('Snapshot has an invalid initial position')
            for text in data['moves']:
                restored.push_uci(text)
            self.initial, self.board = data['initial'], restored
        else:
            raise ValueError(f'Unsupported chess operation: {operation}')

    def close(self):
        if self.engine is not None:
            try:
                self.engine.quit()
            except self.chess.engine.EngineTerminatedError:
                pass  # The dead child has already released its resources.
            finally:
                self.engine.close()


class Glulx:
    capabilities = ['line', 'char', 'resize', 'restart', 'save', 'load']

    def __init__(self, args):
        self.executable = str(Path(args.glulxe).expanduser().resolve())
        self.story = str(Path(args.story).expanduser().resolve())
        self.identity = {'story': hashlib.sha256(Path(self.story).read_bytes()).hexdigest(),
                         'engine': hashlib.sha256(Path(self.executable).read_bytes()).hexdigest()}
        self.storage = tempfile.TemporaryDirectory(prefix='etaf-gamekit-glulx-')
        self.directory = Path(self.storage.name)
        self.width, self.height = 80, 24
        self.display = {'windows': [], 'input': [], 'gen': 0, 'finished': False}
        self.started = False

    @staticmethod
    def text(runs):
        if any('image' in run for run in runs):
            raise ValueError('This frontend supports text-only Glk output')
        return ''.join(run.get('text', '') for run in runs)

    def apply(self, display, update):
        if update.get('type') != 'update':
            raise ValueError(f'Unexpected RemGlk response: {update.get("type")}')
        if update.get('specialinput'):
            raise ValueError('File dialogs are unsupported; use the frontend Save/Load snapshot controls')
        windows = {window['id']: window for window in display['windows']}
        if 'windows' in update:
            current = {}
            for descriptor in update['windows']:
                if descriptor['type'] not in ('buffer', 'grid'):
                    raise ValueError('Only Glk text-buffer and text-grid windows are supported')
                window = windows.get(descriptor['id'], {'text': '', 'lines': []})
                window.update(descriptor)
                if descriptor['type'] == 'grid':
                    if not (1 <= descriptor['gridwidth'] <= 320 and 1 <= descriptor['gridheight'] <= 120):
                        raise ValueError('Glk grid is outside the supported 320 by 120 extent')
                    old = window['lines']
                    window['lines'] = [(old[i] if i < len(old) else '')
                                       for i in range(descriptor['gridheight'])]
                current[descriptor['id']] = window
            windows = current
        for content in update.get('content', []):
            window = windows[content['id']]
            if window['type'] == 'grid':
                if content.get('clear'):
                    window['lines'] = [''] * window['gridheight']
                for line in content.get('lines', []):
                    window['lines'][line['line']] = self.text(line.get('content', []))
            else:
                if content.get('clear'):
                    window['text'] = ''
                for paragraph in content.get('text', []):
                    if not paragraph.get('append') and window['text']:
                        window['text'] += '\n'
                    window['text'] += self.text(paragraph.get('content', []))
                window['text'] = window['text'][-32000:]
        display.update(windows=sorted(windows.values(), key=lambda w: (w['top'], w['left'])),
                       input=update.get('input', []), gen=update['gen'],
                       finished=bool(update.get('exit')))
        if any(item.get('type') not in ('line', 'char') for item in display['input']):
            raise ValueError('This story requested an unsupported input mode')
        return display

    def turn(self, event, *, source=None, display=None, fresh=False):
        # Work on a copy; rejected output and crashed interpreters cannot replace
        # the last accepted VM snapshot or its derived display projection.
        with tempfile.TemporaryDirectory(prefix='etaf-gamekit-turn-') as trial:
            directory = Path(trial)
            source = source or self.directory
            if not fresh:
                for name in ('autosave.json', 'autosave.glksave'):
                    shutil.copy2(source / name, directory / name)
            args = [self.executable, '--autosave', '-singleturn']
            if not fresh:
                args += ['--autorestore', '-autometrics']
            args += [self.story]
            result = subprocess.run(args, cwd=directory, input=json.dumps(event),
                                    text=True, encoding='utf-8', capture_output=True, timeout=10)
            if result.returncode or result.stderr.strip():
                raise ValueError(result.stderr.strip() or f'Glulxe exited with {result.returncode}')
            if len(result.stdout.encode()) > MAX_MESSAGE:
                raise ValueError('RemGlk output exceeds 1 MiB')
            parsed = json.loads(json.dumps(display or self.display))
            # A stanza can span lines. Decode JSON objects, never NDJSON here.
            decoder, remaining, count = json.JSONDecoder(), result.stdout.lstrip(), 0
            while remaining:
                update, end = decoder.raw_decode(remaining)
                parsed = self.apply(parsed, update)
                remaining = remaining[end:].lstrip()
                count += 1
            if not count:
                raise ValueError('Glulxe returned no update')
            for name in ('autosave.json', 'autosave.glksave'):
                if (directory / name).exists():
                    shutil.copy2(directory / name, self.directory / name)
            self.display, self.started = parsed, True

    def view(self):
        inputs = self.display['input']
        return {'kind': 'story', 'title': Path(self.story).stem,
                'status': 'Finished' if self.display['finished'] else
                          ('Enter a command' if inputs else 'No input requested'),
                'windows': self.display['windows'], 'input': inputs,
                'generation': self.display['gen'], 'finished': self.display['finished']}

    def act(self, operation, payload):
        if operation in ('start', 'restart'):
            empty = {'windows': [], 'input': [], 'gen': 0, 'finished': False}
            self.turn({'type': 'init', 'gen': 0,
                       'metrics': {'width': self.width, 'height': self.height}},
                      fresh=True, display=empty)
        elif operation in ('line', 'char'):
            request = next((item for item in self.display['input']
                            if item['id'] == payload.get('window', item['id'])
                            and item['type'] == operation), None)
            if request is None:
                raise ValueError('The game is not requesting that input')
            value = payload['value']
            if not isinstance(value, str) or '\n' in value or '\r' in value:
                raise ValueError('Input must be a single line of text')
            if operation == 'line' and len(value) > request['maxlen']:
                raise ValueError(f'Input exceeds {request["maxlen"]} characters')
            if operation == 'char' and len(value) != 1 and value not in ('return', 'escape', 'space'):
                raise ValueError('Enter one character, return, escape or space')
            self.turn({'type': operation, 'gen': self.display['gen'],
                       'window': request['id'], 'value': value})
        elif operation == 'resize':
            width, height = payload['width'], payload['height']
            if not (isinstance(width, int) and isinstance(height, int)
                    and 20 <= width <= 320 and 5 <= height <= 120):
                raise ValueError('Viewport must be 20..320 columns and 5..120 rows')
            self.turn({'type': 'arrange', 'gen': self.display['gen'],
                       'metrics': {'width': width, 'height': height}})
            self.width, self.height = width, height
        elif operation == 'save':
            if self.display['finished']:
                raise ValueError('Save before the story exits')
            atomic_json(payload['path'], {'format': 'etaf-gamekit/1', 'kind': 'glulx',
                        'identity': self.identity, 'display': self.display,
                        'width': self.width, 'height': self.height,
                        'files': {name: base64.b64encode((self.directory / name).read_bytes()).decode()
                                  for name in ('autosave.json', 'autosave.glksave')}})
        elif operation == 'load':
            data = read_snapshot(payload['path'], 'glulx')
            if data['identity'] != self.identity:
                raise ValueError('Snapshot requires the same story and interpreter build')
            with tempfile.TemporaryDirectory(prefix='etaf-gamekit-restore-') as restored:
                for name in ('autosave.json', 'autosave.glksave'):
                    (Path(restored) / name).write_bytes(base64.b64decode(data['files'][name], validate=True))
                self.turn({'type': 'arrange', 'gen': data['display']['gen'],
                           'metrics': {'width': data['width'], 'height': data['height']}},
                          source=Path(restored), display=data['display'])
                self.width, self.height = data['width'], data['height']
        else:
            raise ValueError(f'Unsupported Glulx operation: {operation}')

    def close(self):
        self.storage.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter', choices=['chess', 'glulx'], required=True)
    parser.add_argument('--stockfish', default='stockfish')
    parser.add_argument('--fen')
    parser.add_argument('--glulxe')
    parser.add_argument('--story')
    args = parser.parse_args()
    if args.adapter == 'glulx' and not (args.glulxe and args.story):
        parser.error('--adapter glulx requires --glulxe and --story')
    def terminate(_signum, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    adapter = Chess(args) if args.adapter == 'chess' else Glulx(args)
    revision, previous = 0, 0
    try:
        while True:
            raw = sys.stdin.buffer.readline(MAX_MESSAGE + 1)
            if not raw:
                break
            if len(raw) > MAX_MESSAGE:
                raise ValueError('Request exceeds 1 MiB')
            request = json.loads(raw)
            identifier = request['id']
            if not isinstance(identifier, int) or identifier <= previous:
                raise ValueError('Request id must increase')
            previous = identifier
            error = None
            try:
                payload = request.get('args', {})
                if not isinstance(payload, dict):
                    raise ValueError('Request args must be an object')
                adapter.act(request['op'], payload)
            except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as failure:
                error = str(failure)
            revision += 1
            print(json.dumps({'version': 1, 'id': identifier, 'revision': revision,
                              'capabilities': adapter.capabilities, 'view': adapter.view(),
                              'error': error}, ensure_ascii=False), flush=True)
    finally:
        adapter.close()


if __name__ == '__main__':
    main()
