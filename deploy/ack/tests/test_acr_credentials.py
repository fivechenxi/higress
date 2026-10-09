#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('credentials', ROOT / 'scripts/with-acr-credentials.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
REGISTRY = 'tokenvolt-acr-registry.cn-beijing.cr.aliyuncs.com'


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.file = self.folder / 'credentials.json'
        self.file.write_text(json.dumps(dict(registry=REGISTRY, username='test-user', password='test-password')))
        self.file.chmod(0o600)
        (self.folder / 'terraform.tfvars').write_text('tokenvolt_acr_registry = "' + REGISTRY + '"\n')
        self.env = {'TOKENVOLT_ACR_CREDENTIAL_FILE': str(self.file)}

    def tearDown(self):
        self.temp.cleanup()

    def test_private_file_loaded_without_mutating_caller(self):
        loaded = module.credential_environment(self.env, self.folder)
        self.assertEqual(loaded['TF_VAR_tokenvolt_acr_password'], 'test-password')
        self.assertNotIn('TF_VAR_tokenvolt_acr_password', self.env)

    def test_process_pair_takes_precedence_and_partial_pair_rejected(self):
        env = dict(self.env, TF_VAR_tokenvolt_acr_username='process-user', TF_VAR_tokenvolt_acr_password='process-password')
        self.file.unlink()
        self.assertEqual(module.credential_environment(env, self.folder)['TF_VAR_tokenvolt_acr_username'], 'process-user')
        del env['TF_VAR_tokenvolt_acr_password']
        with self.assertRaises(ValueError):
            module.credential_environment(env, self.folder)

    def test_public_file_rejected(self):
        self.file.chmod(0o644)
        with self.assertRaises(ValueError):
            module.credential_environment(self.env, self.folder)

    def test_symlink_rejected(self):
        link = self.folder / 'symlink'
        link.symlink_to(self.file)
        with self.assertRaises(OSError):
            module.credential_environment(dict(self.env, TOKENVOLT_ACR_CREDENTIAL_FILE=str(link)), self.folder)

    def test_missing_invalid_empty_and_wrong_registry_rejected(self):
        for data in ['not-json', '[]', '{}', json.dumps(dict(registry=REGISTRY, username='user', password='')), json.dumps(dict(registry='other.cr.aliyuncs.com', username='user', password='pass'))]:
            with self.subTest(data=data):
                self.file.write_text(data)
                with self.assertRaises(ValueError):
                    module.credential_environment(self.env, self.folder)

    def test_process_registry_override_must_match(self):
        with self.assertRaises(ValueError):
            module.credential_environment(dict(self.env, TF_VAR_tokenvolt_acr_registry='other.cr.aliyuncs.com'), self.folder)

    def test_executor_preserves_arguments_and_does_not_log_secrets(self):
        output = self.folder / 'result.json'
        child = self.folder / 'child.py'
        child.write_text('import os,json,sys;open(sys.argv[1],"w").write(json.dumps([os.environ["TF_VAR_tokenvolt_acr_username"],os.environ["TF_VAR_tokenvolt_acr_password"],sys.argv[2:]]))')
        result = subprocess.run(['python3', str(ROOT / 'scripts/with-acr-credentials.py'), 'python3', str(child), str(output), 'argument with spaces'], env=dict(os.environ, **self.env), cwd=self.folder, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text()), ['test-user', 'test-password', ['argument with spaces']])
        self.assertEqual(result.stdout + result.stderr, '')

    def test_tofu_wrapper_checks_config_before_loading_and_bypasses_bootstrap(self):
        scripts = self.folder / 'scripts'
        scripts.mkdir()
        wrapper = scripts / 'tofu.sh'
        wrapper.write_text((ROOT / 'scripts/tofu.sh').read_text())
        (scripts / 'with-acr-credentials.py').write_text((ROOT / 'scripts/with-acr-credentials.py').read_text())
        guard = scripts / 'remote-config.sh'
        marker = self.folder / 'guard-called'
        guard.write_text('#!/bin/sh\n: > "' + str(marker) + '"\n')
        guard.chmod(0o700)
        fake = self.folder / 'fake-tofu'
        fake.write_text('#!/bin/sh\n[ -f "' + str(marker) + '" ] || exit 7\n[ "$TF_VAR_tokenvolt_acr_username" = test-user ] || exit 8\n[ "$TF_VAR_tokenvolt_acr_password" = test-password ] || exit 9\n')
        fake.chmod(0o700)
        env = dict(os.environ, **self.env, TOFU_BIN=str(fake), ALICLOUD_ACCESS_KEY_ID='synthetic', ALICLOUD_ACCESS_KEY_SECRET='synthetic')
        for key in ['TF_VAR_tokenvolt_acr_username', 'TF_VAR_tokenvolt_acr_password', 'TF_VAR_tokenvolt_acr_registry']:
            env.pop(key, None)
        result = subprocess.run(['sh', str(wrapper), 'plan'], env=env, cwd=self.folder, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        marker.unlink()
        fake.write_text('#!/bin/sh\n[ ! -f "' + str(marker) + '" ] || exit 10\n[ -z "${TF_VAR_tokenvolt_acr_password:-}" ] || exit 11\n')
        self.file.unlink()
        for args in [['output'], ['-chdir=bootstrap', 'plan']]:
            result = subprocess.run(['sh', str(wrapper)] + args, env=env, cwd=self.folder, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which('tofu'), 'OpenTofu required for real precondition evaluation')
    def test_actual_terraform_precondition_rejects_ghcr_in_acr_mode(self):
        source = (ROOT / 'tokenvolt.tf').read_text()
        block = re.search(r'precondition \{\n      condition = var.tokenvolt_acr_registry == "" \|\| startswith\([\s\S]*?\n    \}', source).group(0)
        config = self.folder / 'contract'
        config.mkdir()
        (config / 'main.tf').write_text('variable "tokenvolt_acr_registry" { type = string }\nvariable "tokenvolt_control_plane_image" { type = string }\nresource "terraform_data" "contract" {\nlifecycle {\n' + block + '\n}\n}\n')
        result = subprocess.run(['tofu', 'init', '-backend=false', '-input=false', '-no-color'], cwd=config, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        reference = REGISTRY + '/tokenvolt/tokenvolt-control-plane@sha256:' + 'a' * 64
        for registry, image, success in [(REGISTRY, reference, True), (REGISTRY, 'ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:' + 'a' * 64, False), (REGISTRY, reference.replace('cn-beijing', 'cn-hangzhou'), False), (REGISTRY, reference.replace('/tokenvolt-control-plane@', '/openai-fixture@'), False), ('', 'ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:' + 'a' * 64, True)]:
            with self.subTest(registry=registry, image=image):
                result = subprocess.run(['tofu', 'plan', '-input=false', '-no-color', '-var=tokenvolt_acr_registry=' + registry, '-var=tokenvolt_control_plane_image=' + image], cwd=config, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)

    def test_failure_does_not_disclose_malformed_secret(self):
        self.file.write_text('secret-that-must-not-be-logged')
        result = subprocess.run(['python3', str(ROOT / 'scripts/with-acr-credentials.py'), 'echo', 'not executed'], env=dict(os.environ, **self.env), cwd=self.folder, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('secret-that-must-not-be-logged', result.stdout + result.stderr)
        self.assertNotIn('not executed', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
