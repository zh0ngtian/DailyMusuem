#!/usr/bin/env python3
"""Subprocess-only release substitute: temporary files stand in for remote channels."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import time


def atomic(path, value):
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(value), encoding='utf-8')
    temporary.replace(path)


def wait_for(predicate, message):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() >= deadline:
            raise RuntimeError(message)
        time.sleep(.01)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'run'])
    parser.add_argument('phase')
    parser.add_argument('--context', required=True)
    arguments = parser.parse_args()
    context = json.loads(Path(arguments.context).read_text())
    options = context['config']['options']
    root = Path(options['effects_root'])
    root.mkdir(parents=True, exist_ok=True)
    control = json.loads(Path(options['control']).read_text())
    batch = context['id']
    sha = context.get('frozen', {}).get('sha')
    event = {'batch': batch, 'action': arguments.action, 'phase': arguments.phase,
             'sha': sha, 'time': time.time(), 'pid': os.getpid()}
    with (root / 'calls.jsonl').open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(event) + '\n')
        stream.flush()
    if arguments.phase == 'prepare':
        print(json.dumps({'done': True, 'result': {'version': '0.0.0-fake',
                        'buildNumber': '1', 'localValidation': 'temporary substitute'}}))
        return
    marker = root / f'{batch}-{arguments.phase}.json'
    if arguments.action == 'run':
        if control.get('gate_phase') == arguments.phase:
            (root / f'{batch}.waiting').write_text('waiting')
            wait_for(lambda: Path(control['gate']).exists(), 'test gate was not released')
        if control.get('barrier') and arguments.phase == 'github':
            (root / f'{batch}.started').write_text(str(time.time()))
            wait_for(lambda: len(list(root.glob('*.started'))) == 2,
                     'different scopes failed to reach the channel concurrently')
        if arguments.phase == 'ota' and control.get('fail_ota'):
            raise RuntimeError('controlled OTA channel failure')
        result = {'effectVerified': True, 'channel': arguments.phase,
                  'batchId': batch, 'sha': sha, 'effectReceipt': str(marker)}
        atomic(marker, result)
        if arguments.phase == 'github' and control.get('interrupt_owner_once'):
            sentinel = root / 'owner-interrupted'
            if not sentinel.exists():
                sentinel.write_text(batch)
                os.kill(os.getppid(), signal.SIGKILL)
        if arguments.phase == 'github' and control.get('lose_response_once'):
            sentinel = root / 'response-lost'
            if not sentinel.exists():
                sentinel.write_text(batch)
                raise RuntimeError('controlled response lost after channel effect')
    result = json.loads(marker.read_text()) if marker.exists() else {}
    # A receipt for another commit cannot satisfy this batch's reconciliation.
    done = bool(result) and result.get('sha') == sha and result.get('batchId') == batch
    print(json.dumps({'done': done, 'result': result}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
