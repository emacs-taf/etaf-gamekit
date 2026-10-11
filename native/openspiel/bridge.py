#!/usr/bin/env python3
"""GameKit adapter for OpenSpiel's public game/state APIs, with no renderer."""
# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations
import argparse
import importlib.metadata
import json
import math
import os
from pathlib import Path
import random
import sys
import tempfile
import pyspiel

VERSION = importlib.metadata.version('open-spiel')
MAX_MESSAGE = 1024 * 1024
MAX_SNAPSHOT = 8 * MAX_MESSAGE


class Match:
    """Own one native rule state and a separate chance sampler."""

    def __init__(self, specification, player, seed):
        self.game = pyspiel.load_game(specification)
        kind = self.game.get_type()
        if kind.dynamics not in (pyspiel.GameType.Dynamics.SEQUENTIAL, pyspiel.GameType.Dynamics.SIMULTANEOUS):
            raise ValueError('This adapter supports sequential and simultaneous games, not mean-field updates')
        if kind.chance_mode == pyspiel.GameType.ChanceMode.SAMPLED_STOCHASTIC:
            raise ValueError('Sampled-stochastic kernels require an engine-specific RNG adapter')
        self.player = self.valid_player(player)
        self.seed = seed
        self.random = random.Random(seed)
        self.state = self.game.new_initial_state()
        self.resolve_chance(self.state, self.random)

    def valid_player(self, player):
        if type(player) is not int or not 0 <= player < self.game.num_players():
            raise ValueError('Player is outside this game')
        return player

    @staticmethod
    def resolve_chance(state, generator):
        for _ in range(10000):
            if not state.is_chance_node():
                return
            outcomes = state.chance_outcomes()
            state.apply_action(generator.choices([x[0] for x in outcomes], [x[1] for x in outcomes])[0])
        raise ValueError('Chance resolution exceeded 10000 transitions')

    def observe(self):
        state, kind = self.state, self.game.get_type()
        terminal = state.is_terminal()
        legal = [] if terminal else state.legal_actions(self.player)
        return {
            'schema': 'openspiel/1', 'engine': {'name': 'openspiel', 'version': VERSION},
            'game': {'name': kind.short_name, 'specification': str(self.game),
                     'players': self.game.num_players(), 'dynamics': str(kind.dynamics)},
            'player': self.player, 'current_player': state.current_player(),
            'terminal': terminal, 'simultaneous': state.is_simultaneous_node(),
            'legal_actions': [{'id': action, 'label': state.action_to_string(self.player, action)} for action in legal],
            'observation': state.observation_string(self.player) if kind.provides_observation_string else None,
            'observation_tensor': state.observation_tensor(self.player) if kind.provides_observation_tensor else None,
            'information_state': state.information_state_string(self.player) if kind.provides_information_state_string else None,
            'returns': state.returns(), 'rewards': state.rewards(),
        }

    def command(self, operation, args):
        if operation == 'set-player':
            self.player = self.valid_player(args.get('player'))
        elif operation == 'save':
            self.save(self.path(args))
        elif operation == 'load':
            self.restore(self.path(args))
        elif operation == 'reset':
            candidate = self.game.new_initial_state()
            generator = random.Random(self.seed)
            self.resolve_chance(candidate, generator)
            self.state, self.random = candidate, generator
        elif operation in ('act', 'joint-action'):
            if self.state.is_terminal():
                raise ValueError('The game is over')
            candidate = self.state.clone()
            generator = random.Random()
            generator.setstate(self.random.getstate())
            if operation == 'act':
                action = args.get('action')
                if candidate.is_simultaneous_node() or candidate.current_player() != self.player:
                    raise ValueError('Select the active player, or submit a joint action for simultaneous play')
                if type(action) is not int or action not in candidate.legal_actions(self.player):
                    raise ValueError('Illegal action')
                candidate.apply_action(action)
            else:
                actions = args.get('actions')
                if not candidate.is_simultaneous_node() or not isinstance(actions, list) or len(actions) != self.game.num_players():
                    raise ValueError('A simultaneous node needs one action per player')
                if any(type(action) is not int or action not in candidate.legal_actions(player)
                       for player, action in enumerate(actions)):
                    raise ValueError('Illegal joint action')
                candidate.apply_actions(actions)
            self.resolve_chance(candidate, generator)
            self.state, self.random = candidate, generator
        else:
            raise ValueError('Unsupported game operation')

    @staticmethod
    def path(args):
        value = args.get('path')
        if not isinstance(value, str) or not value:
            raise ValueError('A snapshot path is required')
        return Path(value).expanduser().resolve()

    def save(self, path):
        value = {'schema': 'gamekit.openspiel/snapshot-1', 'engine_version': VERSION,
                 'game': str(self.game), 'native': pyspiel.serialize_game_and_state(self.game, self.state),
                 'player': self.player, 'seed': self.seed, 'random': self.random.getstate()}
        encoded = json.dumps(value, allow_nan=False).encode('utf-8')
        if len(encoded) > MAX_SNAPSHOT:
            raise ValueError('Snapshot exceeds 8 MiB')
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + '.', delete=False) as output:
                temporary = Path(output.name)
                output.write(encoded)
            os.replace(temporary, path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()

    def restore(self, path):
        with path.open('rb') as source:
            raw = source.read(MAX_SNAPSHOT + 1)
        if len(raw) > MAX_SNAPSHOT:
            raise ValueError('Snapshot exceeds 8 MiB')
        saved = json.loads(raw)
        if not isinstance(saved, dict) or saved.get('schema') != 'gamekit.openspiel/snapshot-1' or \
                saved.get('engine_version') != VERSION or saved.get('game') != str(self.game) or \
                not isinstance(saved.get('native'), str) or type(saved.get('seed')) is not int:
            raise ValueError('Snapshot does not match this engine and game')
        player = self.valid_player(saved.get('player'))
        state = saved.get('random')
        if not isinstance(state, list) or len(state) != 3 or not isinstance(state[1], list):
            raise ValueError('Invalid saved chance sampler')
        if state[2] is not None and (type(state[2]) not in (int, float) or not math.isfinite(state[2])):
            raise ValueError('Invalid saved Gaussian sample')
        generator = random.Random()
        generator.setstate((state[0], tuple(state[1]), state[2]))
        candidate_game, candidate_state = pyspiel.deserialize_game_and_state(saved['native'])
        if str(candidate_game) != str(self.game) or candidate_state.is_chance_node():
            raise ValueError('Snapshot native state does not match its game')
        self.game, self.state, self.player = candidate_game, candidate_state, player
        self.random, self.seed = generator, saved['seed']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game')
    parser.add_argument('--player', type=int, default=0)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--list', action='store_true', help='List native registered game names.')
    parser.add_argument('--version', action='version', version=f'OpenSpiel {VERSION}')
    options = parser.parse_args()
    if options.list:
        print(json.dumps(pyspiel.registered_names()))
        return 0
    if not options.game:
        parser.error('--game is required unless --list is used')
    match = Match(options.game, options.player, options.seed)
    revision = previous_id = 0
    connected = False
    capabilities = ['act', 'joint-action', 'set-player', 'reset', 'save', 'load']
    while True:
        raw = sys.stdin.buffer.readline(MAX_MESSAGE + 2)
        if not raw:
            return 0
        if len(raw) > MAX_MESSAGE + 1 or not raw.endswith(b'\n'):
            raise ValueError('Oversized or incomplete GameKit request')
        if not raw.strip():
            continue
        request = json.loads(raw)
        if not isinstance(request, dict) or request.get('version') != 1 or \
                type(request.get('id')) is not int or request['id'] <= previous_id or \
                not isinstance(request.get('op'), str) or not isinstance(request.get('args'), dict):
            raise ValueError('Malformed GameKit request')
        previous_id = request['id']
        failure = None
        try:
            if request['op'] == 'start' and not connected:
                connected = True
            else:
                if not connected or request['op'] not in capabilities:
                    raise ValueError('Start once before sending advertised actions')
                match.command(request['op'], request['args'])
        except (ValueError, TypeError, RuntimeError, OSError, KeyError) as error:
            failure = str(error) or type(error).__name__
        revision += 1
        response = json.dumps({'version': 1, 'id': previous_id, 'revision': revision,
                               'capabilities': capabilities, 'observation': match.observe(), 'error': failure},
                              allow_nan=False, ensure_ascii=False)
        if len(response.encode('utf-8')) > MAX_MESSAGE:
            raise ValueError('Observation exceeds 1 MiB')
        print(response, flush=True)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, TypeError, RuntimeError, OSError) as error:
        print(f'OpenSpiel adapter failed: {error}', file=sys.stderr)
        sys.exit(2)
