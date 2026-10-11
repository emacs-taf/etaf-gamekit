"""Exercise the supported adapter command through real external engines."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines'


class Engine:
    def __init__(self, kind, *extra):
        self.number = 0
        self.process = subprocess.Popen(
            [str(CACHE / 'python/bin/python3'), str(ROOT / 'scripts/run-engine.py'),
             '--adapter', kind, *extra], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding='utf-8')

    def request(self, operation, **payload):
        self.number += 1
        self.process.stdin.write(json.dumps({'id': self.number, 'op': operation, 'args': payload}) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError(self.process.stderr.read())
        result = json.loads(line)
        assert result['id'] == self.number
        return result

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=15)
        error = self.process.stderr.read()
        self.process.stdout.close(); self.process.stderr.close()
        if self.process.returncode != 0 or error:
            raise AssertionError(error or self.process.returncode)


class EngineContract(unittest.TestCase):
    def chess(self, fen=None):
        engine = Engine('chess', '--stockfish', str(CACHE / 'bin/stockfish'),
                        *(['--fen', fen] if fen else []))
        self.addCleanup(engine.close)
        self.assertIsNone(engine.request('start')['error'])
        return engine

    def story(self):
        engine = Engine('glulx', '--glulxe', str(CACHE / 'bin/glulxe'),
                        '--story', str(CACHE / 'last-beacon.ulx'))
        self.addCleanup(engine.close)
        self.assertIsNone(engine.request('start')['error'])
        return engine

    def test_illegal_move_preserves_position_and_stockfish_plays_legal_move(self):
        engine = self.chess()
        accepted = engine.request('move', move='e2e4')['view']
        rejected = engine.request('move', move='e2e5')
        self.assertIn('Illegal move', rejected['error'])
        self.assertEqual(accepted['fen'], rejected['view']['fen'])
        reply = engine.request('engine')
        self.assertIsNone(reply['error'])
        self.assertIn(reply['view']['last_move'], accepted['legal'])
        self.assertEqual(len(reply['view']['moves']), 2)

    def test_castling_en_passant_and_underpromotion_use_backend_rules(self):
        castle = self.chess('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1')
        result = castle.request('move', move='e1g1')
        self.assertIsNone(result['error'])
        self.assertEqual(result['view']['board'][-1], 'R . . . . R K .')
        passing = self.chess()
        for move in ('e2e4', 'a7a6', 'e4e5', 'd7d5', 'e5d6'):
            result = passing.request('move', move=move)
            self.assertIsNone(result['error'])
        self.assertEqual(result['view']['board'][2][6], 'P')
        self.assertEqual(result['view']['board'][3][6], '.')
        promotion = self.chess('7k/P7/1K6/8/8/8/8/8 w - - 0 1')
        result = promotion.request('move', move='a7a8n')
        self.assertIsNone(result['error'])
        self.assertEqual(result['view']['board'][0][0], 'N')

    def test_chess_snapshot_restores_history_and_rejects_corruption(self):
        engine = self.chess()
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'chess.json')
            before = engine.request('move', move='e2e4')['view']
            self.assertIsNone(engine.request('save', path=path)['error'])
            engine.request('move', move='e7e5')
            restored = engine.request('load', path=path)
            self.assertEqual(restored['view']['fen'], before['fen'])
            self.assertEqual(restored['view']['moves'], ['e2e4'])
            Path(path).write_text('{"format":"etaf-gamekit/1","kind":"chess","initial":"broken"}')
            failed = engine.request('load', path=path)
            self.assertTrue(failed['error'])
            self.assertEqual(failed['view']['fen'], before['fen'])
            self.assertEqual(engine.request('undo')['view']['moves'], [])

    def test_story_completes_and_echoes_each_command_once(self):
        engine = self.story()
        for command in ('take lantern', 'turn on lantern', 'north', 'take prism',
                        'north', 'put prism in beacon'):
            result = engine.request('line', value=command)
            self.assertIsNone(result['error'])
        transcript = '\n'.join(w['text'] for w in result['view']['windows'] if w['type'] == 'buffer')
        self.assertIn('You have won', transcript)
        self.assertNotIn('>take lanterntake lantern', transcript)
        self.assertEqual(transcript.count('>take lantern'), 1)

    def test_story_snapshot_and_resize_preserve_native_world(self):
        engine = self.story()
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'story.json')
            engine.request('line', value='take lantern')
            saved = engine.request('save', path=path)
            self.assertIsNone(saved['error'])
            engine.request('line', value='north')
            loaded = engine.request('load', path=path)
            self.assertIsNone(loaded['error'])
            self.assertIn('Workshop', loaded['view']['windows'][0]['lines'][0])
            result = engine.request('line', value='inventory')
            text = next(w['text'] for w in result['view']['windows'] if w['type'] == 'buffer')
            self.assertIn('a brass lantern', text)
            resized = engine.request('resize', width=60, height=20)
            self.assertIsNone(resized['error'])
            self.assertEqual(resized['view']['windows'][0]['gridwidth'], 60)
            bad = json.loads(Path(path).read_text()); bad['identity']['story'] = 'different'
            Path(path).write_text(json.dumps(bad))
            failed = engine.request('load', path=path)
            self.assertIn('same story', failed['error'])
            self.assertEqual(failed['view'], resized['view'])

    def test_sessions_have_independent_native_state(self):
        first, second = self.story(), self.story()
        first.request('line', value='take lantern')
        result = second.request('line', value='look')
        text = next(w['text'] for w in result['view']['windows'] if w['type'] == 'buffer')
        self.assertIn('You can see a brass lantern here.', text)

    def test_setup_read_only_commands(self):
        command = ['python3', str(ROOT / 'scripts/setup-engines.py')]
        manifest = subprocess.run([*command, '--manifest'], capture_output=True, text=True, check=True)
        self.assertIn('sha256', json.loads(manifest.stdout)['glulxe'])
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([*command, '--check', '--cache', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(set(json.loads(result.stdout)['missing']), {'python', 'glulxe', 'stockfish', 'story'})
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
