"""MuseumMuse coordinator acceptance with isolated git repositories and fake channels.

Run: python3 -B -m unittest discover -s scripts/tests -p test_release_coordinator_acceptance.py -v
Override the installed runtime with RELEASE_COORDINATOR_SOURCE=/path/to/release-coordinator.
No service is started; no production database, network, signing or deployment is used.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest


def coordinator_source():
    override = os.environ.get('RELEASE_COORDINATOR_SOURCE')
    if override:
        source = Path(override).expanduser().resolve()
    else:
        installation = Path.home() / 'Library/Application Support/ReleaseCoordinator/installation.json'
        if not installation.is_file():
            raise RuntimeError('ReleaseCoordinator is required; install it or set RELEASE_COORDINATOR_SOURCE')
        source = Path(json.loads(installation.read_text())['runtime']).expanduser().resolve()
    if source.name == 'release_coordinator' and (source / 'engine.py').is_file():
        source = source.parent
    if not (source / 'release_coordinator/engine.py').is_file():
        raise RuntimeError(f'Invalid ReleaseCoordinator source: {source}')
    return source


SOURCE = coordinator_source()
sys.path.insert(0, str(SOURCE))
from release_coordinator.engine import Scheduler, Worker
from release_coordinator.store import Conflict, Store

ADAPTER = Path(__file__).parent / 'fixtures/museum_fake_adapter.py'
VALID = {'checks': [{'name': 'acceptance-input', 'status': 'passed'}]}


class FakeClock:
    def __init__(self, path):
        self.path = path
        self.set(100.)

    def set(self, value):
        self.path.write_text(str(value))

    def __call__(self):
        return float(self.path.read_text())


def git(root, *arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments],
                                   text=True, stderr=subprocess.PIPE).strip()


def wait_for(predicate):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('Timed out waiting for a controlled test checkpoint')
        time.sleep(.01)


class CoordinatorAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='museum-coordinator-acceptance-')
        self.root = Path(self.temporary.name)
        self.clock = FakeClock(self.root / 'clock')
        self.store = Store(self.root / 'state', self.clock)
        self.effects = self.root / 'effects'
        self.configs = {}
        self.repositories = {}

    def tearDown(self):
        self.temporary.cleanup()

    def project(self, name='museum', **controls):
        repository = self.root / name
        repository.mkdir()
        git(repository, 'init', '-b', 'main')
        git(repository, 'config', 'user.name', 'Acceptance')
        git(repository, 'config', 'user.email', 'acceptance@example.invalid')
        (repository / 'base.txt').write_text('base\n')
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', 'Base')
        remote = self.root / f'{name}.git'
        subprocess.run(['git', 'clone', '--bare', str(repository), str(remote)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        git(repository, 'remote', 'add', 'origin', str(remote))
        control = self.root / f'{name}-control.json'
        control.write_text(json.dumps(controls))
        config = self.store.add_project({
            'id': name, 'repository': str(repository), 'remote': str(remote),
            'target': 'museum-ios-private', 'environment': 'acceptance-only',
            'adapter': [sys.executable, '-B', str(ADAPTER)], 'phases': ['github', 'ota'],
            'required_checks': ['acceptance-input'],
            'options': {'effects_root': str(self.effects), 'control': str(control)},
        })
        self.configs[name] = config
        self.repositories[name] = repository
        return config

    def controls(self, name='museum', **updates):
        path = Path(self.configs[name]['options']['control'])
        value = json.loads(path.read_text())
        value.update(updates)
        path.write_text(json.dumps(value))

    def ready(self, task, name='museum', base='main', **registration):
        repository = self.repositories[name]
        git(repository, 'checkout', '-b', task, base)
        (repository / f'{task}.txt').write_text(task + '\n')
        git(repository, 'add', '.')
        git(repository, 'commit', '-m', task)
        sha = git(repository, 'rev-parse', 'HEAD')
        git(repository, 'push', 'origin', task)
        git(repository, 'checkout', 'main')
        self.store.register(name, task, **registration)
        self.store.ready(task, sha, VALID)
        return sha

    def calls(self, batch=None, action=None, phase=None):
        path = self.effects / 'calls.jsonl'
        values = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [value for value in values if
                (batch is None or value['batch'] == batch) and
                (action is None or value['action'] == action) and
                (phase is None or value['phase'] == phase)]

    def assert_single_effect(self, batch, phase):
        self.assertEqual(len(self.calls(batch, 'run', phase)), 1)
        result = json.loads((self.effects / f'{batch}-{phase}.json').read_text())
        self.assertEqual(result['sha'], self.store.batch(batch)['data']['frozen']['sha'])
        self.assertTrue(result['effectVerified'])

    def receipt(self, task):
        row = self.store.task(task)
        batch = row['recovered_by'] or row['batch']
        return json.loads((self.store.root / 'receipts' / f'{batch}.json').read_text())

    def test_different_scopes_execute_channels_concurrently(self):
        for name in ('museum-a', 'museum-b'):
            self.project(name, barrier=True)
            self.ready(f'{name}-change', name)
        scheduler = Scheduler(self.store)
        scheduler.tick()
        threads = [thread for thread, _ in scheduler.workers.values()]
        self.assertEqual(len(threads), 2)
        for thread in threads:
            thread.join(15)
            self.assertFalse(thread.is_alive())
        batches = self.store.snapshot()['batches']
        self.assertEqual(len(batches), 2)
        self.assertEqual({batch['state'] for batch in batches}, {'complete'})
        for batch in batches:
            self.assert_single_effect(batch['id'], 'github')
            self.assert_single_effect(batch['id'], 'ota')

    def test_one_scope_has_one_owner_and_stale_owner_is_fenced(self):
        config = self.project()
        self.ready('change')
        barrier = threading.Barrier(3)
        results = []

        def claim(owner):
            independent = Store(self.store.root, self.clock)
            barrier.wait()
            results.append((owner, independent.claim(config['scope'], owner)))

        threads = [threading.Thread(target=claim, args=(owner,)) for owner in ('first', 'second')]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(5)
            self.assertFalse(thread.is_alive())
        winners = [(owner, epoch) for owner, epoch in results if epoch is not None]
        self.assertEqual(len(winners), 1)
        owner, epoch = winners[0]
        batch = self.store.create_batch('museum', owner, epoch)
        self.assertIsNone(Worker(self.store, 'museum', owner='competitor').run(batch['id']))
        self.assertEqual(self.calls(), [])
        self.clock.set(161)
        successor = self.store.claim(config['scope'], 'successor')
        self.assertGreater(successor, epoch)
        for stale_write in (
            lambda: self.store.heartbeat(config['scope'], owner, epoch),
            lambda: self.store.save(batch['id'], owner, epoch, batch, 'running'),
            lambda: self.store.step(batch['id'], 'github', 'verified', {}, owner, epoch),
        ):
            with self.assertRaises(Conflict):
                stale_write()
        self.store.release(config['scope'], owner, epoch)
        self.store.guard(config['scope'], 'successor', successor)
        self.store.release(config['scope'], 'successor', successor)
        completed = Worker(self.store, 'museum').run(batch['id'])
        self.assertIsNotNone(completed)
        self.assert_single_effect(batch['id'], 'github')

    def test_90_second_deadline_does_not_restart_on_ready_or_arrival(self):
        self.project()
        self.store.register('museum', 'active-peer')
        sha = self.ready('first')
        self.clock.set(170)
        self.store.ready('first', sha, VALID)
        self.ready('later')
        self.assertEqual(self.store.due('museum')['deadline'], 190)
        self.clock.set(189)
        self.assertIsNone(Worker(self.store, 'museum').run())
        self.assertEqual(self.calls(), [])
        self.clock.set(190)
        completed = Worker(self.store, 'museum').run()
        self.assertEqual({task['id'] for task in completed['tasks']}, {'first', 'later'})
        self.assert_single_effect(completed['id'], 'github')

    def test_closing_peer_extends_only_to_180_seconds(self):
        self.project()
        self.store.register('museum', 'closing-peer')
        self.ready('first')
        self.clock.set(160)
        self.store.touch('closing-peer', 'closing')
        self.clock.set(270)
        self.store.touch('closing-peer')
        self.ready('late')
        self.assertEqual(self.store.due('museum')['deadline'], 280)
        self.clock.set(279)
        self.assertIsNone(Worker(self.store, 'museum').run())
        self.clock.set(280)
        completed = Worker(self.store, 'museum').run()
        self.assertEqual({task['id'] for task in completed['tasks']}, {'first', 'late'})
        self.assertEqual(self.store.task('closing-peer')['state'], 'closing')
        self.assert_single_effect(completed['id'], 'ota')

    def test_task_arriving_after_freeze_enters_next_batch(self):
        gate = self.root / 'continue'
        self.project(gate_phase='github', gate=str(gate))
        self.ready('first')
        results = []
        thread = threading.Thread(target=lambda: results.append(Worker(self.store, 'museum').run()))
        thread.start()
        try:
            wait_for(lambda: self.effects.exists() and bool(list(self.effects.glob('*.waiting'))))
            first = self.store.snapshot()['batches'][0]
            frozen = copy.deepcopy(first['data']['frozen'])
            self.ready('after-freeze')
            self.assertIsNone(self.store.task('after-freeze')['batch'])
            self.assertIsNone(Worker(self.store, 'museum').run())
        finally:
            gate.write_text('continue')
            thread.join(15)
        self.assertFalse(thread.is_alive())
        self.assertIsNotNone(results[0])
        self.assertEqual(results[0]['frozen'], frozen)
        next_batch = Worker(self.store, 'museum').run()
        self.assertNotEqual(first['id'], next_batch['id'])
        self.assertEqual([task['id'] for task in next_batch['tasks']], ['after-freeze'])
        self.assertEqual([task['id'] for task in results[0]['tasks']], ['first'])

    def test_lost_response_reconciles_effect_without_second_channel_run(self):
        self.project(lose_response_once=True)
        self.ready('change')
        completed = Worker(self.store, 'museum').run()
        self.assertIsNotNone(completed)
        self.assertEqual(self.store.batch(completed['id'])['state'], 'complete')
        self.assertGreaterEqual(len(self.calls(completed['id'], 'check', 'github')), 2)
        self.assert_single_effect(completed['id'], 'github')
        self.assert_single_effect(completed['id'], 'ota')
        self.assertEqual(self.receipt('change')['id'], completed['id'])

    def test_killed_owner_reconciles_existing_effect_after_lease_expiry(self):
        config = self.project(interrupt_owner_once=True)
        self.ready('change')
        code = ('import sys; from pathlib import Path; '
                'from release_coordinator.store import Store; '
                'from release_coordinator.engine import Worker; '
                'clock=Path(sys.argv[2]); '
                'store=Store(sys.argv[1],lambda:float(clock.read_text())); '
                'Worker(store,"museum",owner="killed-owner").run()')
        environment = {**os.environ, 'PYTHONPATH': str(SOURCE), 'PYTHONDONTWRITEBYTECODE': '1'}
        process = subprocess.Popen([sys.executable, '-B', '-c', code, str(self.store.root),
                                    str(self.clock.path)], env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.communicate(timeout=15)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertEqual(process.returncode, -9)
        batch = self.store.snapshot()['batches'][0]
        frozen = copy.deepcopy(batch['data']['frozen'])
        self.assertEqual(batch['state'], 'running')
        self.assertEqual(len(self.calls(batch['id'], 'run', 'github')), 1)
        self.assertIsNone(Worker(self.store, 'museum', owner='early-owner').run(batch['id']))
        with self.assertRaises(Conflict):
            self.store.resume(batch['id'])
        self.clock.set(161)
        self.store.resume(batch['id'])
        completed = Worker(self.store, 'museum', owner='replacement').run(batch['id'])
        self.assertIsNotNone(completed)
        self.assertEqual(completed['frozen'], frozen)
        self.assert_single_effect(batch['id'], 'github')
        self.assert_single_effect(batch['id'], 'ota')
        checks = self.calls(batch['id'], 'check', 'github')
        self.assertGreaterEqual(len(checks), 2)
        self.assertEqual(self.receipt('change')['id'], batch['id'])
        lease = [lease for lease in self.store.snapshot()['leases'] if lease['scope'] == config['scope']][0]
        self.assertGreater(lease['epoch'], 1)

    def test_failed_channel_latest_leaf_repair_and_shared_recovered_receipt(self):
        self.project(fail_ota=True)
        original_sha = self.ready('original')
        self.assertIsNone(Worker(self.store, 'museum').run())
        parent = self.store.snapshot()['batches'][0]
        parent_before = copy.deepcopy(self.store.batch(parent['id']))
        self.assertEqual(parent['state'], 'failed')
        self.assertIn('controlled OTA channel failure', parent['error'])
        self.assert_single_effect(parent['id'], 'github')
        self.assertFalse((self.effects / f'{parent["id"]}-ota.json').exists())
        self.assertIn('github', parent['data']['results'])
        with self.assertRaises(Conflict):
            self.store.resume(parent['id'])
        self.ready('unrelated')
        scheduler = Scheduler(self.store)
        scheduler.tick()
        self.assertFalse(scheduler.workers)
        self.assertIsNone(self.store.due('museum'))
        self.ready('repair-one', base=original_sha, repairs_batch=parent['id'])
        self.assertIsNone(Worker(self.store, 'museum').run())
        first_child = [batch for batch in self.store.snapshot()['batches'] if batch['id'] != parent['id']][0]
        child_before = copy.deepcopy(self.store.batch(first_child['id']))
        self.assertEqual(first_child['state'], 'failed')
        self.assertIsNone(self.store.due('museum'))
        with self.assertRaises(Conflict):
            self.store.register('museum', 'stale-repair', repairs_batch=parent['id'])
        self.controls(fail_ota=False)
        self.ready('repair-two', base=self.store.task('repair-one')['sha'],
                   repairs_batch=first_child['id'])
        completed = Worker(self.store, 'museum').run()
        self.assertIsNotNone(completed)
        self.assertEqual(completed['recoveryOf'], first_child['id'])
        self.assertEqual(completed['recoveryChain'], [parent['id'], first_child['id']])
        self.assertEqual({task['id'] for task in completed['tasks']}, {'original', 'repair-one', 'repair-two'})
        self.assertEqual(completed['newTaskIds'], ['repair-two'])
        self.assertEqual(self.store.batch(parent['id']), parent_before)
        self.assertEqual(self.store.batch(first_child['id']), child_before)
        for task in ('original', 'repair-one'):
            row = self.store.task(task)
            self.assertEqual(row['state'], 'recovered')
            self.assertEqual(row['recovered_by'], completed['id'])
        self.assertEqual(self.store.task('repair-two')['state'], 'complete')
        receipts = [self.receipt(task) for task in ('original', 'repair-one', 'repair-two')]
        self.assertEqual(receipts[0], receipts[1])
        self.assertEqual(receipts[1], receipts[2])
        self.assertEqual(receipts[0]['id'], completed['id'])
        self.assertEqual(receipts[0]['frozen']['sha'], completed['frozen']['sha'])
        for task in completed['tasks']:
            git(completed['workspace'], 'merge-base', '--is-ancestor', task['sha'], completed['frozen']['sha'])
        for batch in (parent, first_child):
            self.assert_single_effect(batch['id'], 'github')
            self.assertEqual(len(self.calls(batch['id'], 'run', 'ota')), 1)
        self.assert_single_effect(completed['id'], 'github')
        self.assert_single_effect(completed['id'], 'ota')
        self.assertIsNone(self.store.task('unrelated')['batch'])


if __name__ == '__main__':
    unittest.main()
