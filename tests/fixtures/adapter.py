#!/usr/bin/env python3
"""Controllable protocol peer for public transport/lifecycle scenarios."""
import json
import os
import sys
import time

mode = sys.argv[1]
revision = 0
for line in sys.stdin:
    request = json.loads(line)
    if mode == 'crash':
        sys.stderr.write('fixture engine stopped\n'); sys.exit(7)
    if mode == 'hang':
        time.sleep(10); continue
    revision += 1
    view = {'kind': 'grid', 'title': 'Protocol fixture', 'status': 'Ready',
            'columns': 8, 'rows': ['frame-0'], 'pid': os.getpid()}
    reply = {'version': 1, 'id': request['id'], 'revision': revision,
             'capabilities': ['step'], 'view': view, 'error': None}
    if mode == 'stale' and request['op'] == 'step':
        reply['revision'] = 1
    if mode == 'malformed':
        reply['view']['rows'] = ['too wide for the declared columns']
    if mode == 'bad-object':
        reply = 42
    if mode == 'bad-window':
        reply['view'] = {'kind': 'story', 'title': 'Bad window', 'status': '',
                         'generation': 1, 'input': [],
                         'windows': [{'id': 1, 'type': 'grid', 'gridheight': 1,
                                      'gridwidth': 8, 'lines': 42}]}
    if mode == 'rejection' and request['op'] == 'step':
        reply['error'] = 'Action rejected'
    encoded = json.dumps(reply) + '\n'
    if mode == 'split':
        middle = len(encoded) // 2
        sys.stdout.write(encoded[:middle]); sys.stdout.flush(); time.sleep(0.02)
        sys.stdout.write(encoded[middle:]); sys.stdout.flush()
    else:
        print(encoded, end='', flush=True)
    if mode == 'rejection' and request['op'] == 'step':
        revision += 1
        reply.update(id=None, revision=revision, error=None)
        print(json.dumps(reply), flush=True)
    if mode == 'burst' and request['op'] == 'step':
        for number in range(1, 101):
            revision += 1
            reply.update(id=None, revision=revision)
            reply['view']['rows'] = [f'{number:08d}']
            print(json.dumps(reply), flush=True)
