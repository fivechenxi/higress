# Copyright 2026 alibaba
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

"""Render both ingress modes and verify their authentication/routing boundaries."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1] / 'charts/tokenvolt'


def render(split, managed_redis=False):
    values = {
        'controlPlane': {
            'image': 'example.invalid/control-plane@sha256:' + 'a' * 64,
            'allowedOrigin': 'https://ack.tokenvolt.net',
            'rrsaRoleName': 'fixture-role',
            'publicService': {
                'enabled': split,
                'annotations': {
                    'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id': 'lb-shared',
                    'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners': 'false',
                    'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-vgroup-port': 'rsp-portal:8000',
                },
            },
            'cloud': dict.fromkeys(['slsRegionId', 'slsEndpoint', 'slsProject', 'slsLogstore',
                                   'ossRegionId', 'ossEndpoint', 'ossBucket'], 'fixture'),
        },
        'portal': {'directEntry': split},
        'publicEntry': {'host': 'api.tokenvolt.net' if split else 'ack.tokenvolt.net'},
        'higress': {
            'policyPluginUrl': 'oci://example.invalid/policy@sha256:' + 'b' * 64,
            'gatewayConfigPublisher': {'enabled': True},
            'aiStatistics': {'pluginUrl': 'https://example.invalid/stats.wasm', 'pluginSha256': 'c' * 64},
            'rateLimits': {
                'enabled': managed_redis,
                'domains': ['api.tokenvolt.net'],
                'requestPlugin': {
                    'url': 'https://example.invalid/sha256/' + 'd' * 64 + '.wasm',
                    'sha256': 'd' * 64,
                },
                'tokenPlugin': {
                    'url': 'https://example.invalid/sha256/' + 'e' * 64 + '.wasm',
                    'sha256': 'e' * 64,
                },
                'redis': {
                    'serviceName': 'r-test.redis.rds.aliyuncs.com.dns',
                    'servicePort': 6379,
                    'password': 'fixture-password',
                },
            },
        },
        'rateLimitRedis': {'enabled': False},
    }
    with tempfile.NamedTemporaryFile(mode='w') as f:
        json.dump(values, f)
        f.flush()
        result = subprocess.run(['helm', 'template', 'tokenvolt', str(CHART),
                                 '--namespace', 'tokenvolt-system', '-f', f.name],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


class PublicEntryTest(unittest.TestCase):
    def test_managed_redis_configures_plugins_without_in_cluster_redis(self):
        objects = render(True, managed_redis=True)
        self.assertFalse(any(o['kind'] == 'Deployment' and
                             o['metadata']['name'] == 'tokenvolt-rate-limit-redis'
                             for o in objects))
        plugins = [o for o in objects if o['kind'] == 'WasmPlugin' and
                   o['metadata']['labels'].get('tokenvolt.ai/managed') == 'rate-limit']
        self.assertEqual(len(plugins), 4)
        for plugin in plugins:
            redis = plugin['spec']['defaultConfig']['redis']
            self.assertEqual(redis['service_name'], 'r-test.redis.rds.aliyuncs.com.dns')
            self.assertEqual(redis['service_port'], 6379)
            self.assertEqual(redis['password'], 'fixture-password')

    def test_split_entry_exposes_only_model_paths_through_higress(self):
        objects = render(True)
        ingresses = [o for o in objects if o['kind'] == 'Ingress']
        self.assertNotIn('tokenvolt-portal', [o['metadata']['name'] for o in ingresses])
        for ingress in ingresses:
            for rule in ingress['spec']['rules']:
                self.assertNotEqual(rule['host'], 'ack.tokenvolt.net')
                self.assertTrue(all(p['path'].startswith('/v1') for p in rule['http']['paths']))
        service = next(o for o in objects if o['kind'] == 'Service'
                       and o['metadata']['name'] == 'tokenvolt-control-plane-public')
        self.assertEqual(service['spec']['type'], 'LoadBalancer')
        self.assertEqual(service['spec']['ports'][0]['port'], 8000)
        self.assertEqual(service['metadata']['annotations'][
            'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners'], 'false')
        deployment = next(o for o in objects if o['kind'] == 'Deployment'
                          and o['metadata']['name'] == 'tokenvolt-control-plane')
        self.assertEqual(service['spec']['selector'], deployment['spec']['selector']['matchLabels'])
        env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['ALLOWED_ORIGIN'], 'https://ack.tokenvolt.net')
        self.assertEqual(env['HIGRESS_PUBLIC_HOST'], 'api.tokenvolt.net')

    def test_default_mode_keeps_existing_shared_host(self):
        objects = render(False)
        self.assertFalse(any(o['metadata']['name'] == 'tokenvolt-control-plane-public' for o in objects))
        portal = next(o for o in objects if o['kind'] == 'Ingress' and o['metadata']['name'] == 'tokenvolt-portal')
        self.assertIn('ack.tokenvolt.net', [r['host'] for r in portal['spec']['rules']])


if __name__ == '__main__':
    unittest.main()
