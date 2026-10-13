# Copyright 2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LegacyDisabledTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.marker = self.work / 'unexpected-call'
        for name in ('aliyun', 'tofu', 'terraform', 'kubectl', 'helm', 'curl', 'git'):
            stub = self.bin / name
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$LEGACY_TEST_MARKER"\nexit 97\n')
            stub.chmod(0o700)
        self.env = {'PATH': str(self.bin) + ':/usr/bin:/bin',
                    'LEGACY_TEST_MARKER': str(self.marker)}

    def run_command(self, args, **extra):
        return subprocess.run(args, cwd=ROOT, env=dict(self.env, **extra),
                              capture_output=True, text=True, timeout=10)

    def assert_blocked(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('Legacy TokenVolt deployment is disabled', result.stderr)
        self.assertFalse(self.marker.exists(), 'external tool ran before the guard')

    def test_make_entrypoints_and_parallel_prerequisites_are_blocked(self):
        targets = ['backend-bootstrap', 'backend-migrate', 'init', 'config-push',
                   'artifacts-sync', 'ai-proxy-artifact', 'ai-proxy-artifact-publish',
                   'plan', 'start', 'stop', 'destroy']
        for target in targets:
            with self.subTest(target=target):
                self.assert_blocked(self.run_command(['make', target]))
        self.assert_blocked(self.run_command(['make']))
        self.assert_blocked(self.run_command(['make', '-j8', 'start', 'stop']))

    def test_direct_shell_entrypoints_are_blocked(self):
        cases = [('sh', 'bootstrap-backend.sh', []),
                 ('sh', 'migrate-state.sh', []),
                 ('bash', 'migrate-to-baseline-pool.sh', ['--execute']),
                 ('bash', 'sync-artifacts.sh', []),
                 ('bash', 'sync-ai-proxy-artifact.sh', ['--publish']),
                 ('sh', 'remote-config.sh', ['push', '--force']),
                 ('sh', 'remote-config.sh', ['prepare'])]
        for shell, script, args in cases:
            with self.subTest(script=script, args=args):
                self.assert_blocked(self.run_command([shell, str(ROOT/'scripts'/script), *args]))

    def test_tofu_all_forms_blocked_before_credentials_or_backend(self):
        for args in (['plan'], ['apply', 'saved.tfplan'], ['destroy'],
                     ['-chdir=backend-bootstrap', 'apply'], ['state', 'push', 'old.json'],
                     ['init', '-migrate-state'], ['output']):
            with self.subTest(args=args):
                self.assert_blocked(self.run_command(['sh', str(ROOT/'scripts/tofu.sh'), *args]))

    def test_direct_credential_wrapper_is_blocked_before_secret_read(self):
        result = self.run_command([sys.executable, str(ROOT/'scripts/with-acr-credentials.py'), 'tofu', 'apply'],
                                  TOKENVOLT_ACR_CREDENTIAL_FILE='/nonexistent-secret')
        self.assert_blocked(result)
        self.assertNotIn('ACR credential loading failed', result.stderr)

    def test_only_exact_emergency_value_is_accepted(self):
        guard = ['sh', str(ROOT/'scripts/legacy-deployment-guard.sh')]
        for value in ('', 'true', '1', 'approved-emergency '):
            with self.subTest(value=value):
                self.assert_blocked(self.run_command(guard, TOKENVOLT_LEGACY_DEPLOYMENT=value))
        self.assertEqual(self.run_command(guard, TOKENVOLT_LEGACY_DEPLOYMENT='approved-emergency').returncode, 0)
        self.assert_blocked(self.run_command(guard))

    def test_emergency_wrapper_reaches_only_a_local_stub(self):
        result = self.run_command(['sh', str(ROOT/'scripts/tofu.sh'), 'output'],
                                  TOKENVOLT_LEGACY_DEPLOYMENT='approved-emergency',
                                  ALICLOUD_ACCESS_KEY_ID='synthetic', ALICLOUD_ACCESS_KEY_SECRET='synthetic')
        self.assertEqual(result.returncode, 97)
        self.assertEqual(self.marker.read_text().strip(), str(self.bin/'tofu'))

    def test_read_only_config_operations_do_not_hit_disable_guard(self):
        # Isolated copy: no actual remote config or local tfvars is touched.
        scripts = self.work / 'scripts'
        scripts.mkdir()
        for name in ('remote-config.sh', 'legacy-deployment-guard.sh'):
            shutil.copyfile(ROOT/'scripts'/name, scripts/name)
        for action in ('pull', 'status', 'history'):
            with self.subTest(action=action):
                result = self.run_command(['sh', str(scripts/'remote-config.sh'), action])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing remote-config.hcl', result.stderr)
                self.assertNotIn('Legacy TokenVolt deployment is disabled', result.stderr)
                self.assertFalse(self.marker.exists())


if __name__ == '__main__':
    unittest.main()
