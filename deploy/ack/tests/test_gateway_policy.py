#!/usr/bin/env python3
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

"""Helm contract tests: uv run --with pyyaml python deploy/ack/tests/test_gateway_policy.py"""
import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


def render(chart, *arguments):
    result = subprocess.run(['helm', 'template', 'test', str(ROOT / chart),
                             '--namespace', 'higress-system', *arguments],
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def gateway(objects):
    return next(item for item in objects if item['kind'] == 'Deployment'
                and item['metadata']['name'] == 'higress-gateway')


class GatewayPolicyTest(unittest.TestCase):
    def test_parent_chart_and_lock_pin_current_core(self):
        core = yaml.safe_load((ROOT / 'helm/core/Chart.yaml').read_text())['version']
        for name in ['Chart.yaml', 'Chart.lock']:
            wrapper = yaml.safe_load((ROOT / 'helm/higress' / name).read_text())
            dependency = next(d for d in wrapper['dependencies'] if d['name'] == 'higress-core')
            self.assertEqual(dependency['version'], core)

    def test_ack_does_not_reset_hpa_and_waits_for_new_capacity(self):
        deployment = gateway(render('helm/core', '-f', str(ROOT / 'deploy/ack/values/higress-test.yaml')))
        spec = deployment['spec']
        self.assertNotIn('replicas', spec)
        self.assertEqual(spec['strategy']['rollingUpdate'], {'maxSurge': 1, 'maxUnavailable': 0})
        self.assertGreaterEqual(spec['minReadySeconds'], 10)
        pod = spec['template']['spec']
        self.assertEqual(pod['terminationGracePeriodSeconds'], 660)
        container = pod['containers'][0]
        env = {item['name']: item.get('value') for item in container['env']}
        self.assertEqual(env['EXIT_ON_ZERO_ACTIVE_CONNECTIONS'], 'true')
        command = container['lifecycle']['preStop']['exec']['command'][-1]
        self.assertIn('/healthcheck/fail', command)
        self.assertIn('sleep 15', command)

    def test_node_reclamation_outlasts_gateway_grace(self):
        deployment = gateway(render('helm/core', '-f', str(ROOT / 'deploy/ack/values/higress-test.yaml')))
        grace = deployment['spec']['template']['spec']['terminationGracePeriodSeconds']
        source = (ROOT / 'deploy/ack/node_pool.tf').read_text()
        limit = int(re.search(r'max_graceful_termination_sec\s*=\s*(\d+)', source).group(1))
        self.assertGreater(limit, grace)

    def test_generic_chart_keeps_existing_defaults(self):
        spec = gateway(render('helm/core'))['spec']
        self.assertIn('replicas', spec)
        self.assertNotIn('terminationGracePeriodSeconds', spec['template']['spec'])
        self.assertNotIn('lifecycle', spec['template']['spec']['containers'][0])

    def test_only_business_requests_drive_gateway_hpa(self):
        objects = render('deploy/ack/charts/higress-ack-ops', '--set', 'monitoring.enabled=false')
        hpas = {o['metadata']['name']: o['spec'] for o in objects if o['kind'] == 'HorizontalPodAutoscaler'}
        gw = hpas['higress-gateway']
        self.assertEqual((gw['minReplicas'], gw['maxReplicas']), (2, 4))
        self.assertEqual(gw['metrics'], [{'type': 'Pods', 'pods': {
            'metric': {'name': 'higress_active_streams'},
            'target': {'type': 'AverageValue', 'averageValue': '225'}}}])
        self.assertEqual(hpas['higress-controller']['metrics'][0]['resource']['name'], 'cpu')
        self.assertEqual(gw['behavior']['scaleDown']['stabilizationWindowSeconds'], 300)

    def test_missing_business_metric_cannot_silently_fall_back_to_cpu(self):
        for setting in ['prometheusAdapter.enabled=false', 'autoscaling.gateway.activeStreams.enabled=false']:
            with self.subTest(setting=setting), self.assertRaisesRegex(RuntimeError, 'Gateway autoscaling requires'):
                render('deploy/ack/charts/higress-ack-ops', '--set', 'monitoring.enabled=false', '--set', setting)

    def test_grafana_uses_secret_subroute_and_local_bounded_prometheus(self):
        objects = render(
            'deploy/ack/charts/higress-ack-ops',
            '--set', 'monitoring.remoteWriteUrl=http://example.invalid/api/v1/write',
            '--set', 'monitoring.clusterId=test-cluster',
        )
        by_kind_name = {(o['kind'], o['metadata']['name']): o for o in objects}

        deployment = by_kind_name[('Deployment', 'higress-grafana')]
        container = deployment['spec']['template']['spec']['containers'][0]
        self.assertIn('@sha256:', container['image'])
        env = {item['name']: item for item in container['env']}
        self.assertEqual(
            env['GF_SECURITY_ADMIN_PASSWORD']['valueFrom']['secretKeyRef'],
            {'name': 'higress-grafana-admin', 'key': 'admin-password'},
        )
        self.assertEqual(env['GF_SERVER_SERVE_FROM_SUB_PATH']['value'], 'true')

        ingress = by_kind_name[('Ingress', 'higress-grafana')]
        self.assertEqual(ingress['spec']['ingressClassName'], 'higress')
        rule = ingress['spec']['rules'][0]
        self.assertEqual(rule['host'], 'ack.tokenvolt.net')
        self.assertEqual(rule['http']['paths'][0]['path'], '/grafana')

        provisioning = by_kind_name[('ConfigMap', 'higress-grafana-provisioning')]['data']
        self.assertIn('http://higress-metrics-collector.higress-system.svc:9090', provisioning['datasource.yaml'])
        self.assertIn('/var/lib/grafana/dashboards', provisioning['dashboards.yaml'])
        self.assertIn(('ConfigMap', 'higress-grafana-dashboards'), by_kind_name)


if __name__ == '__main__':
    unittest.main()
