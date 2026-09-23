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

"""Contract checks for the optional ACK ALB edge."""
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[3]
CHART = ROOT / 'helm/core'
OVERLAY = ROOT / 'deploy/ack/values/higress-test.yaml'
OPTIONS = (
    '--set', 'albIngress.enabled=true',
    '--set', 'albIngress.host=api.example.com',
    '--set-json', 'albIngress.vSwitchIds=["vsw-zone-a","vsw-zone-b"]',
    '--set', 'albIngress.certificateId=cert-example',
)


def render(*options):
    result = subprocess.run(
        ['helm', 'template', 'higress', str(CHART), '--namespace', 'higress-system',
         '-f', str(OVERLAY), *options], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return [obj for obj in yaml.safe_load_all(result.stdout) if obj]


class AlbIngressTest(unittest.TestCase):
    def test_default_does_not_create_alb_or_change_clb_service(self):
        baseline = render()
        enabled = render(*OPTIONS)
        kinds = {'AlbConfig', 'Ingress'}
        self.assertFalse(any(obj['kind'] in kinds or
                             (obj['kind'] == 'IngressClass' and
                              obj['metadata']['name'] == 'higress-gateway-alb')
                             for obj in baseline))
        service = lambda objects: next(obj for obj in objects if obj['kind'] == 'Service'
                                       and obj['metadata']['name'] == 'higress-gateway')
        self.assertEqual(service(baseline), service(enabled))
        self.assertEqual(service(enabled)['spec']['type'], 'LoadBalancer')

    def test_enabled_uses_gateway_service_and_900_second_listeners(self):
        objects = render(*OPTIONS)
        by_kind = {obj['kind']: obj for obj in objects if obj['kind'] in
                   {'AlbConfig', 'Ingress'}}
        config = by_kind['AlbConfig']
        listeners = config['spec']['listeners']
        self.assertEqual([(item['port'], item['protocol']) for item in listeners],
                         [(80, 'HTTP'), (443, 'HTTPS')])
        self.assertTrue(all(item['requestTimeout'] == 900 and
                            item['idleTimeout'] == 900 for item in listeners))
        self.assertEqual(listeners[1]['certificates'],
                         [{'CertificateId': 'cert-example', 'IsDefault': True}])
        self.assertEqual([item['vSwitchId'] for item in
                          config['spec']['config']['zoneMappings']],
                         ['vsw-zone-a', 'vsw-zone-b'])
        cls = next(obj for obj in objects if obj['kind'] == 'IngressClass' and
                   obj['metadata']['name'] == 'higress-gateway-alb')
        self.assertEqual(cls['spec']['parameters']['name'], config['metadata']['name'])
        ingress = by_kind['Ingress']
        self.assertEqual(ingress['spec']['ingressClassName'], cls['metadata']['name'])
        self.assertEqual(ingress['spec']['rules'][0]['host'], 'api.example.com')
        self.assertEqual(ingress['spec']['rules'][0]['http']['paths'][0]['backend'],
                         {'service': {'name': 'higress-gateway', 'port': {'number': 80}}})
        annotations = ingress['metadata']['annotations']
        self.assertEqual(annotations['alb.ingress.kubernetes.io/healthcheck-path'], '/healthz')
        self.assertEqual(annotations['alb.ingress.kubernetes.io/healthcheck-method'], 'GET')

    def test_enabled_requires_independent_edge_inputs(self):
        for args in [('--set', 'albIngress.enabled=true'),
                     (*OPTIONS, '--set', 'albIngress.certificateId='),
                     (*OPTIONS, '--set-json', 'albIngress.vSwitchIds=["same","same"]')]:
            with self.subTest(args=args), self.assertRaises(RuntimeError):
                render(*args)


if __name__ == '__main__':
    unittest.main()
