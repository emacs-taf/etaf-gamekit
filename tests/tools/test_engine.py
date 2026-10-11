"""Exercise native backend command, observation and snapshot contracts."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines'


class Engine:
    def __init__(self, command=None, expected_stderr=''):
        self.number = self.revision = 0
        self.expected_stderr = expected_stderr
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            command or [str(CACHE / 'bin/godot'), '--headless', '--no-header', '--path',
             str(ROOT / 'examples/salvage'), '--script', str(ROOT / 'native/godot/gamekit.gd')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8')
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def receive(self, timeout=10):
        line = self.messages.get(timeout=timeout)
        if line is None:
            raise AssertionError('Backend stopped: ' + self.process.stderr.read())
        result = json.loads(line)
        assert result['version'] == 1
        assert result['revision'] > self.revision
        self.revision = result['revision']
        return result

    def request(self, operation, **payload):
        self.number += 1
        self.process.stdin.write(json.dumps({'version': 1, 'id': self.number,
                                             'op': operation, 'args': payload}) + '\n')
        self.process.stdin.flush()
        while True:
            result = self.receive()
            if result['id'] == self.number:
                return result
            assert result['id'] is None

    def until(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.receive(max(0.01, deadline - time.monotonic()))
            if predicate(result['observation']):
                return result['observation']
        raise AssertionError('Expected game state was not reached')

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('Backend did not exit after stdin closed')
        finally:
            self.reader.join(timeout=1)
            error = self.process.stderr.read()
            self.process.stdout.close()
            self.process.stderr.close()
        if self.process.returncode != 0 or error != self.expected_stderr:
            raise AssertionError(f'Unexpected engine exit/diagnostics: {self.process.returncode}: {error!r}')


def pilot(view):
    return next(entity for entity in view['world']['entities'] if entity['kind'] == 'pilot')


class EngineContract(unittest.TestCase):
    def engine(self):
        engine = Engine()
        self.addCleanup(engine.close)
        response = engine.request('start')
        self.assertIsNone(response['error'])
        self.assertEqual(response['observation']['schema'], 'salvage/1')
        return engine

    def test_rejected_coordinates_and_blocked_tiles_preserve_paused_state(self):
        engine = self.engine()
        before = engine.request('save', path='/missing-gamekit-directory/run.json')['observation']
        for operation, values in [('navigate', {'x': 9, 'y': 1}),
                                   ('move', {'x': 1, 'y': 1}),
                                   ('move', {'x': 1.5, 'y': 0}),
                                   ('navigate', {'x': 'bad', 'y': 4}),
                                   ('load', {'path': 12})]:
            rejected = engine.request(operation, **values)
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], before)
        self.assertTrue(engine.request('repair')['error'])
        self.assertEqual(engine.request('navigate', x=12, y=3)['observation']['pilot']['health'], 100)

    def test_pathfinding_crosses_doorways_and_real_simulation_can_win(self):
        engine = self.engine()
        plotted = engine.request('navigate', x=12, y=3)['observation']
        self.assertIn([9, 4], plotted['world']['route'])
        self.assertEqual((pilot(plotted)['x'], pilot(plotted)['y']), (4, 4))
        self.assertIsNone(engine.request('pause')['error'])
        first = engine.until(lambda view: view['pilot']['cores'] == 1)
        self.assertGreater(first['mission']['seconds'], 0)
        pulsed = engine.request('pulse')
        self.assertIsNone(pulsed['error'])
        self.assertLess(pulsed['observation']['mission']['drones'], 3)
        self.assertTrue(engine.request('pulse')['error'])
        self.assertIsNone(engine.request('shield')['error'])
        for count, x, y in [(2, 26, 4), (3, 26, 14)]:
            self.assertIsNone(engine.request('navigate', x=x, y=y)['error'])
            engine.until(lambda view: view['pilot']['cores'] >= count)
        self.assertIsNone(engine.request('navigate', x=3, y=14)['error'])
        won = engine.until(lambda view: view['mission']['won'])
        self.assertGreaterEqual(won['pilot']['score'], 750)
        self.assertFalse(won['mission']['lost'])
        rejected = engine.request('move', x=1, y=0)
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], won)
        restarted = engine.request('restart')['observation']
        self.assertEqual(restarted['pilot']['cores'], 0)
        self.assertTrue(restarted['mission']['paused'])

    def test_damage_repair_and_defeat_are_authoritative(self):
        engine = self.engine()
        engine.request('navigate', x=12, y=3)
        engine.request('pause')
        engine.until(lambda view: view['pilot']['health'] <= 88)
        damaged = engine.request('pause')['observation']
        repaired = engine.request('repair')
        self.assertIsNone(repaired['error'])
        self.assertEqual(repaired['observation']['pilot']['health'], min(100, damaged['pilot']['health'] + 40))
        self.assertEqual(repaired['observation']['pilot']['repairs'], 1)
        engine.request('pause')
        lost = engine.until(lambda view: view['mission']['lost'], timeout=15)
        self.assertEqual(lost['pilot']['health'], 0)
        self.assertFalse(lost['mission']['won'])
        rejected = engine.request('move', x=1, y=0)
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], lost)

    def test_snapshot_restores_progress_and_bad_input_is_atomic(self):
        engine = self.engine()
        engine.request('navigate', x=12, y=3)
        engine.request('pause')
        engine.until(lambda view: view['pilot']['cores'] == 1)
        before = engine.request('pause')['observation']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'run.json'
            self.assertIsNone(engine.request('save', path=str(path))['error'])
            self.assertTrue(path.is_file())
            engine.request('restart')
            restored = engine.request('load', path=str(path))
            self.assertIsNone(restored['error'])
            view = restored['observation']
            self.assertEqual(view['pilot'], before['pilot'])
            self.assertEqual(pilot(view), pilot(before))
            self.assertTrue(view['mission']['paused'])
            identifiers = [event['id'] for event in view['events']]
            self.assertEqual(len(identifiers), len(set(identifiers)))
            for invalid in ('{broken', '{}', '[]', 'x' * (1024 * 1024 + 1)):
                path.write_text(invalid)
                rejected = engine.request('load', path=str(path))
                self.assertTrue(rejected['error'])
                self.assertEqual(rejected['observation'], view)

    def test_sessions_own_independent_worlds(self):
        first, second = self.engine(), self.engine()
        first.request('navigate', x=7, y=4)
        first.request('pause')
        moved = first.until(lambda view: pilot(view)['x'] == 7)
        other = second.request('save', path='/missing-gamekit-directory/run.json')['observation']
        self.assertNotEqual(pilot(moved), pilot(other))
        self.assertEqual((pilot(other)['x'], pilot(other)['y']), (4, 4))
        self.assertEqual(other['mission']['seconds'], 0)

    def test_setup_manifest_missing_cache_and_existing_executable(self):
        command = ['python3', str(ROOT / 'scripts/setup-engine.py')]
        manifest = subprocess.run([*command, '--manifest'], capture_output=True, text=True, check=True)
        self.assertIn('sha256', json.loads(manifest.stdout)['platforms']['macos-universal'])
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([*command, '--check', '--cache', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Engine setup failed', result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])
            installed = subprocess.run([*command, '--cache', directory, '--godot', str(CACHE / 'bin/godot')],
                                       capture_output=True, text=True, check=True)
            self.assertTrue(Path(json.loads(installed.stdout)['godot']).is_symlink())
            checked = subprocess.run([*command, '--check', '--cache', directory],
                                     capture_output=True, text=True, check=True)
            self.assertIn('4.', json.loads(checked.stdout)['version'])


class RuleKernelContracts(unittest.TestCase):
    def backend(self, name, game=None, expected_stderr=''):
        if name == 'boardgame-io':
            command = ['node', str(ROOT / 'native/boardgame-io/bridge.cjs'), '--game',
                       str(ROOT / 'tests/fixtures/tabletop.cjs'), '--player', '0', '--seed', 'contract']
        else:
            command = [str(CACHE / 'openspiel/bin/python'), str(ROOT / 'native/openspiel/bridge.py'),
                       '--game', game, '--player', '0', '--seed', '42']
        engine = Engine(command, expected_stderr)
        self.addCleanup(engine.close)
        response = engine.request('start')
        self.assertIsNone(response['error'])
        return engine, response['observation']

    def test_boardgame_rules_turns_phases_undo_and_player_views(self):
        engine, before = self.backend('boardgame-io', expected_stderr='ERROR: invalid move: claim args: 99\n')
        self.assertNotIn('hands', before['state']['G'])
        rejected = engine.request('move', name='claim', args=[99])
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], before)
        self.assertEqual(engine.request('move', name='claim', args=[2])['observation']['state']['G']['pool'], 10)
        self.assertEqual(engine.request('undo')['observation']['state']['G']['pool'], 12)
        self.assertEqual(engine.request('redo')['observation']['state']['G']['pool'], 10)
        self.assertEqual(engine.request('event', name='endTurn')['observation']['state']['ctx']['currentPlayer'], '1')
        inactive = engine.request('move', name='claim', args=[2])
        self.assertTrue(inactive['error'])
        engine.request('set-player', player='1')
        engine.request('move', name='claim', args=[3])
        engine.request('event', name='endTurn')
        engine.request('set-player', player='0')
        final = engine.request('move', name='claim', args=[1])
        self.assertIsNone(final['error'])
        self.assertEqual(final['observation']['state']['ctx']['phase'], 'final')
        spectator = engine.request('set-player', player=None)['observation']
        self.assertIsNone(spectator['state']['G']['hand'])

    def test_boardgame_replay_snapshot_restores_rng_and_rejects_bad_input(self):
        engine, _ = self.backend('boardgame-io')
        engine.request('move', name='claim', args=[2])
        before = engine.request('set-player', player='1')['observation']
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'tabletop.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset')
            loaded = engine.request('load', path=str(target))
            self.assertIsNone(loaded['error'])
            self.assertEqual(loaded['observation'], before)
            for text in ('{}', '{broken', '[]'):
                target.write_text(text)
                bad = engine.request('load', path=str(target))
                self.assertTrue(bad['error'])
                self.assertEqual(bad['observation'], before)

    def test_openspiel_resolves_chance_and_validates_player_actions(self):
        engine, before = self.backend('openspiel', 'kuhn_poker')
        self.assertEqual(before['current_player'], 0)
        self.assertEqual([a['id'] for a in before['legal_actions']], [0, 1])
        bad = engine.request('act', action=999)
        self.assertTrue(bad['error'])
        self.assertEqual(bad['observation'], before)
        passed = engine.request('act', action=0)['observation']
        self.assertEqual(passed['current_player'], 1)
        self.assertEqual(passed['legal_actions'], [])
        self.assertTrue(engine.request('act', action=0)['error'])
        engine.request('set-player', player=1)
        ended = engine.request('act', action=0)['observation']
        self.assertTrue(ended['terminal'])
        self.assertEqual(sum(ended['returns']), 0)
        self.assertTrue(engine.request('act', action=0)['error'])

    def test_openspiel_simultaneous_actions_use_the_native_joint_transition(self):
        engine, before = self.backend('openspiel', 'matrix_rps')
        self.assertTrue(before['simultaneous'])
        self.assertEqual(len(before['legal_actions']), 3)
        bad = engine.request('joint-action', actions=[0])
        self.assertTrue(bad['error'])
        self.assertEqual(bad['observation'], before)
        ended = engine.request('joint-action', actions=[0, 1])
        self.assertIsNone(ended['error'])
        self.assertTrue(ended['observation']['terminal'])
        self.assertEqual(ended['observation']['returns'], [-1, 1])

    def test_openspiel_native_snapshot_preserves_progress_and_future_legality(self):
        engine, _ = self.backend('openspiel', 'kuhn_poker')
        before = engine.request('act', action=0)['observation']
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'native.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset')
            restored = engine.request('load', path=str(target))
            self.assertIsNone(restored['error'])
            self.assertEqual(restored['observation'], before)
            target.write_text('{}')
            rejected = engine.request('load', path=str(target))
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], before)
        engine.request('set-player', player=1)
        self.assertTrue(engine.request('act', action=0)['observation']['terminal'])

    def test_openspiel_undo_redo_restores_chance_and_survives_snapshots(self):
        engine, initial = self.backend('openspiel', 'solitaire')
        self.assertFalse(initial['can_undo'])
        self.assertTrue(engine.request('undo')['error'])
        action = next(item['id'] for item in initial['legal_actions'] if item['id'] != 0)
        played = engine.request('act', action=action)['observation']
        self.assertEqual(played['action_count'], 1)
        undone = engine.request('undo')['observation']
        expected = dict(initial, can_redo=True)
        self.assertEqual(undone, expected)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'history.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset', seed=123)
            self.assertEqual(engine.request('load', path=str(target))['observation'], expected)
            self.assertEqual(engine.request('redo')['observation'], played)
        engine.request('undo')
        self.assertEqual(engine.request('act', action=action)['observation'], played)
        self.assertTrue(engine.request('redo')['error'])

    def test_openspiel_seeded_reset_and_invalid_history_are_atomic(self):
        engine, initial = self.backend('openspiel', 'solitaire')
        other = engine.request('reset', seed=99)['observation']
        self.assertNotEqual(other['observation'], initial['observation'])
        self.assertEqual(engine.request('reset', seed=42)['observation'], initial)
        rejected = engine.request('reset', seed='not-an-integer')
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], initial)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'history.snapshot'
            engine.request('save', path=str(target))
            saved = json.loads(target.read_text())
            saved['past'] = [{'native': 3}]
            target.write_text(json.dumps(saved))
            rejected = engine.request('load', path=str(target))
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], initial)

    def test_openspiel_catalog_is_discoverable_without_starting_a_game(self):
        output = subprocess.run([str(CACHE / 'openspiel/bin/python'),
                                 str(ROOT / 'native/openspiel/bridge.py'), '--list'],
                                capture_output=True, text=True, check=True)
        self.assertEqual(output.stderr, '')
        self.assertTrue({'kuhn_poker', 'matrix_rps', 'tic_tac_toe'} <= set(json.loads(output.stdout)))


if __name__ == '__main__':
    unittest.main()
