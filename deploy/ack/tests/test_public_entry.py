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


def render(split, managed_redis=False, dashboard=None, quota=False, redis=None, in_cluster=False, archive=None, billing=None, neutoken_clusters=None):
    values = {
        'controlPlane': {
            'quotaEnabled': quota,
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
        'rateLimitRedis': {'enabled': in_cluster},
    }
    if redis is not None:
        values['higress']['rateLimits']['redis'].update(redis)
    if dashboard is not None:
        values['controlPlane']['usageDashboard'] = dashboard
    if archive is not None:
        values['controlPlane']['archive'] = archive
    if billing is not None:
        values['controlPlane']['billing'] = billing
    if neutoken_clusters is not None:
        values['higress']['neutokenSingleUseClusters'] = neutoken_clusters
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
    def test_neutoken_connection_mitigation_is_opt_in_and_exactly_scoped(self):
        name = 'tokenvolt-neutoken-single-use-connections'
        self.assertFalse(any(o['metadata']['name'] == name for o in render(True)))
        clusters = [
            'outbound|443||tokenvolt-mp-' + 'a' * 40 + '.dns',
            'outbound|443||tokenvolt-mp-' + 'b' * 40 + '.dns',
        ]
        obj, = [o for o in render(True, neutoken_clusters=clusters) if o['metadata']['name'] == name]
        self.assertEqual(obj['metadata']['namespace'], 'higress-system')
        self.assertEqual(obj['spec']['workloadSelector']['labels'], {'app': 'higress-gateway'})
        self.assertEqual([p['match']['cluster']['name'] for p in obj['spec']['configPatches']], clusters)
        self.assertTrue(all(p['applyTo'] == 'CLUSTER' and
                            p['patch']['value']['max_requests_per_connection'] == 1
                            for p in obj['spec']['configPatches']))
        with self.assertRaises(RuntimeError):
            render(True, neutoken_clusters=[clusters[0], clusters[0]])
        with self.assertRaises(RuntimeError):
            render(True, neutoken_clusters=['outbound|443||unrelated.dns'])

    def test_archive_is_opt_in_and_requires_a_complete_shadow_configuration(self):
        def env_for(config):
            objects = render(True, archive=config)
            deployment = next(o for o in objects if o['kind'] == 'Deployment'
                              and o['metadata']['name'] == 'tokenvolt-control-plane')
            return {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}

        self.assertNotIn('USAGE_ARCHIVE_PRODUCER_ENABLED', env_for(None))
        config = {'producerEnabled': True, 'derivedEnabled': True, 'reconcileEnabled': True,
                  'sourceId': 'sls-access', 'environmentId': 'shadow',
                  'prefix': 'usage-archive/shadow/',
                  'sourceEnvironments': {'sls-access': 'shadow'},
                  'allowedConsumers': ['tv-test-key-id'],
                  'startCursors': [{'shard': {'ID': 0, 'CreatedAt': 1, 'Status': 'readwrite'},
                                    'cursor': 'approved'}]}
        env = env_for(config)
        self.assertEqual(env['USAGE_ARCHIVE_PRODUCER_ENABLED'], 'true')
        self.assertEqual(json.loads(env['USAGE_ARCHIVE_START_CURSORS']), config['startCursors'])
        self.assertEqual(json.loads(env['USAGE_ARCHIVE_ALLOWED_CONSUMERS']), config['allowedConsumers'])
        self.assertEqual(json.loads(env['USAGE_ARCHIVE_SOURCE_ENVIRONMENTS']), config['sourceEnvironments'])
        with self.assertRaisesRegex(RuntimeError, 'exactly one consumer scope'):
            render(True, archive={**config, 'allowedConsumers': []})
        with self.assertRaisesRegex(RuntimeError, 'archive producer requires derived workers'):
            render(True, archive={**config, 'derivedEnabled': False})

        production = {**config, 'allowedConsumers': [], 'allTokenVoltConsumers': True,
                      'environmentId': 'ack-prod', 'prefix': 'usage-archive/ack-prod/',
                      'sourceEnvironments': {'sls-access': 'ack-prod'}}
        billing = {'invoicesV2Enabled': True, 'generationEnabled': True,
                   'publicationEnabled': True, 'environmentId': 'ack-prod',
                   'sourceId': 'sls-access'}
        objects = render(True, archive=production, billing=billing)
        deployment = next(o for o in objects if o['kind'] == 'Deployment'
                          and o['metadata']['name'] == 'tokenvolt-control-plane')
        env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['USAGE_ARCHIVE_ALL_TOKENVOLT_CONSUMERS'], 'true')
        self.assertEqual(env['INVOICE_PUBLICATION_ENABLED'], 'true')
        self.assertEqual(env['INVOICE_ENVIRONMENT_ID'], 'ack-prod')

    def test_managed_redis_has_one_matching_outbound_cluster(self):
        for port in (6379, 6380):
            objects = render(True, managed_redis=True, redis={'servicePort': port})
            filters = [o for o in objects if o['kind'] == 'EnvoyFilter'
                       and o['metadata']['name'] == 'tokenvolt-quota-redis-cluster']
            self.assertEqual(len(filters), 1)
            obj = filters[0]
            self.assertEqual(obj['metadata']['namespace'], 'higress-system')
            self.assertEqual(obj['spec']['workloadSelector']['labels'], {'app': 'higress-gateway'})
            patch, = obj['spec']['configPatches']
            self.assertEqual(patch['applyTo'], 'CLUSTER')
            self.assertEqual(patch['patch']['operation'], 'ADD')
            cluster = patch['patch']['value']
            self.assertEqual(cluster['type'], 'STRICT_DNS')
            for plugin in [o for o in objects if o['kind'] == 'WasmPlugin'
                           and o['metadata']['labels'].get('tokenvolt.ai/managed') == 'rate-limit']:
                redis = plugin['spec']['defaultConfig']['redis']
                self.assertEqual(cluster['name'], f"outbound|{redis['service_port']}||{redis['service_name']}")
            assignment = cluster['load_assignment']
            self.assertEqual(assignment['cluster_name'], cluster['name'])
            address = assignment['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']
            self.assertEqual(address, {'address': 'r-test.redis.rds.aliyuncs.com', 'port_value': port})
            self.assertNotIn('fixture-password', json.dumps(obj))

    def test_disabled_and_kubernetes_redis_do_not_add_duplicate_cluster(self):
        for objects in (render(True), render(True, managed_redis=True, in_cluster=True,
                        redis={'serviceName': 'tokenvolt-rate-limit-redis.tokenvolt-system.svc.cluster.local'})):
            self.assertFalse(any(o['kind'] == 'EnvoyFilter' and
                                 o['metadata']['name'] == 'tokenvolt-quota-redis-cluster' for o in objects))

    def test_managed_endpoint_cannot_enable_in_cluster_redis(self):
        with self.assertRaisesRegex(RuntimeError, 'managed DNS Redis'):
            render(True, managed_redis=True, in_cluster=True)

    def test_empty_dns_hostname_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'hostname must not be empty'):
            render(True, managed_redis=True, redis={'serviceName': '.dns'})

    def test_quota_switch_survives_chart_rendering(self):
        for enabled in (False, True):
            objects = render(True, quota=enabled)
            deployment = next(o for o in objects if o['kind'] == 'Deployment'
                              and o['metadata']['name'] == 'tokenvolt-control-plane')
            env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
            self.assertEqual(env['HIGRESS_QUOTA_ENABLED'], str(enabled).lower())


    def test_dashboard_source_is_explicit_and_survives_chart_rendering(self):
        for config in (None, {'environment': 'ack-test', 'source': 'legacy_usage'}):
            objects = render(True, dashboard=config)
            deployment = next(o for o in objects if o['kind'] == 'Deployment'
                              and o['metadata']['name'] == 'tokenvolt-control-plane')
            env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
            if config is None:
                self.assertNotIn('USAGE_DASHBOARD_ENVIRONMENT', env)
                self.assertNotIn('USAGE_DASHBOARD_SOURCE', env)
            else:
                self.assertEqual(env['USAGE_DASHBOARD_ENVIRONMENT'], 'ack-test')
                self.assertEqual(env['USAGE_DASHBOARD_SOURCE'], 'legacy_usage')
            self.assertNotIn('INVOICE_GENERATION_ENABLED', env)

    def test_partial_dashboard_config_fails_before_deployment(self):
        for config in ({'environment': 'ack-test', 'source': ''},
                       {'environment': '', 'source': 'legacy_usage'}):
            with self.assertRaisesRegex(RuntimeError, 'usageDashboard'):
                render(True, dashboard=config)

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
