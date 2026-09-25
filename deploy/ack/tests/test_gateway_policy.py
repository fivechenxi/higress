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
import json
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
    def test_dirty_archive_external_metric_requires_control_plane_scrape(self):
        base = ('--set', 'monitoring.remoteWriteUrl=http://example.invalid/api/v1/write',
                '--set', 'monitoring.clusterId=test-cluster',
                '--set', 'monitoring.controlPlane.metricsSecretName=fixture-metrics')
        disabled = render('deploy/ack/charts/higress-ack-ops', *base)
        disabled_by_name = {(o['kind'], o['metadata']['name']): o for o in disabled}
        self.assertNotIn(('APIService', 'v1beta1.external.metrics.k8s.io'), disabled_by_name)
        self.assertNotIn('externalRules:', disabled_by_name[('ConfigMap', 'higress-prometheus-adapter')]['data']['config.yaml'])
        objects = render('deploy/ack/charts/higress-ack-ops', *base,
                         '--set', 'prometheusAdapter.externalMetrics.enabled=true')
        by_name = {(o['kind'], o['metadata']['name']): o for o in objects}
        adapter = by_name[('ConfigMap', 'higress-prometheus-adapter')]['data']['config.yaml']
        self.assertIn('externalRules:', adapter)
        self.assertIn('tokenvolt_dirty_partition_ready', adapter)
        self.assertIn('tokenvolt_dirty_partition_running', adapter)
        self.assertIn('namespaced: false', adapter)
        self.assertIn(('APIService', 'v1beta1.external.metrics.k8s.io'), by_name)
        self.assertEqual(by_name[('APIService', 'v1beta1.external.metrics.k8s.io')]['spec']['versionPriority'], 100)
        self.assertEqual(by_name[('APIService', 'v1beta1.custom.metrics.k8s.io')]['spec']['versionPriority'], 100)
        with self.assertRaisesRegex(RuntimeError, 'authenticated control-plane scrape'):
            render('deploy/ack/charts/higress-ack-ops',
                   '--set', 'monitoring.remoteWriteUrl=http://example.invalid/api/v1/write',
                   '--set', 'monitoring.clusterId=test-cluster',
                   '--set', 'prometheusAdapter.externalMetrics.enabled=true')

    def test_quota_alerts_follow_live_redis_counters_and_cr_limits(self):
        objects = render(
            'deploy/ack/charts/higress-ack-ops',
            '--set', 'monitoring.remoteWriteUrl=http://example.invalid/api/v1/write',
            '--set', 'monitoring.clusterId=test-cluster',
            '--set', 'monitoring.quotaMetrics.enabled=true',
            '--set', 'monitoring.quotaMetrics.redisHost=r-test.redis.rds.aliyuncs.com.dns',
            '--set', 'monitoring.quotaMetrics.existingSecret=higress-rate-limit-redis-auth',
            '--set', 'monitoring.alerting.feishu.enabled=true',
        )
        by_kind_name = {(item['kind'], item['metadata']['name']): item for item in objects}
        configmap = by_kind_name[('ConfigMap', 'higress-metrics-collector')]
        collector = by_kind_name[('Deployment', 'higress-metrics-collector')]
        quota = next(c for c in collector['spec']['template']['spec']['containers']
                     if c['name'] == 'quota-metrics')
        env = {item['name']: item for item in quota['env']}
        self.assertEqual(env['REDIS_HOST']['value'], 'r-test.redis.rds.aliyuncs.com.dns')
        self.assertEqual(env['REDIS_PASSWORD']['valueFrom']['secretKeyRef'], {
            'name': 'higress-rate-limit-redis-auth', 'key': 'password'})
        namespace = {'__name__': 'quota_exporter_test'}
        exec(compile(configmap['data']['quota-exporter.py'], 'quota-exporter.py', 'exec'), namespace)

        def plugin(rule_items):
            return {'spec': {'matchRules': [{'config': {'rule_items': rule_items}}]}}

        plugins = {
            'tokenvolt-customer-rate-limit': plugin([
                {'limit_by_header': 'x-tokenvolt-tenant-id',
                 'limit_keys': [{'key': 'tenant-a', 'query_per_minute': 100}]},
                {'limit_by_header': 'x-tokenvolt-tenant-model',
                 'limit_keys': [{'key': 'tenant-a:glm-5.2', 'query_per_minute': 50}]},
            ]),
            'tokenvolt-trial-token-quota': plugin([
                {'limit_by_consumer': '',
                 'limit_keys': [
                     {'key': 'trial-key-id', 'token_total': 100,
                      'expires_at': '2999-01-01T00:00:00Z'},
                     {'key': 'expired-key-id', 'token_total': 100,
                      'expires_at': '2000-01-01T00:00:00Z'},
                 ]},
            ]),
            'tokenvolt-postpaid-token-quota': plugin([
                {'limit_by_header': 'x-tokenvolt-tenant-id',
                 'limit_keys': [{'key': 'tenant-a', 'token_total': 200, 'period': 3600}]},
            ]),
        }
        namespace['kubernetes_get'] = plugins.__getitem__

        def values(keys):
            result = {}
            for key in keys:
                if 'tenant-model' in key:
                    result[key] = 45
                elif 'trial-token-quota' in key:
                    result[key] = 100
                elif 'postpaid-token-quota' in key:
                    result[key] = 200
                else:
                    result[key] = 90
            return result

        namespace['redis_values'] = values
        metrics = namespace['collect']()
        self.assertIn('tokenvolt_customer_rpm_utilization{model="",scope="tenant",tenant="tenant-a"} 0.9', metrics)
        self.assertIn('tokenvolt_customer_rpm_utilization{model="glm-5.2",scope="tenant-model",tenant="tenant-a"} 0.9', metrics)
        self.assertIn('tokenvolt_trial_key_quota_unavailable{consumer="trial-key-id",reason="exhausted"} 1', metrics)
        self.assertIn('tokenvolt_trial_key_quota_unavailable{consumer="expired-key-id",reason="expired"} 1', metrics)
        self.assertIn('tokenvolt_postpaid_tenant_token_quota_exhausted{tenant="tenant-a"} 1', metrics)

        alerts = configmap['data']['alerts.yml']
        self.assertIn('HigressCustomerRPMNearLimit', alerts)
        self.assertIn('HigressTrialKeyQuotaUnavailable', alerts)
        self.assertIn('HigressPostpaidTenantTokenQuotaExhausted', alerts)
        self.assertNotIn('HigressProviderUnexpectedRateLimited', alerts)
        self.assertNotIn('HigressProviderModelRPMCapacityHigh', alerts)
        relay = by_kind_name[('ConfigMap', 'higress-feishu-alert-relay')]['data']['relay.py']
        self.assertIn("labels.get('tenant')", relay)
        self.assertIn("labels.get('consumer')", relay)
        self.assertIn("annotations['dashboard_url']", relay)

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
        self.assertEqual((gw['minReplicas'], gw['maxReplicas']), (4, 4))
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
        self.assertEqual(
            env['GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH']['value'],
            '/var/lib/grafana/dashboards/tokenvolt-model-quality.json',
        )
        data_volume = next(volume for volume in deployment['spec']['template']['spec']['volumes']
                           if volume['name'] == 'data')
        self.assertEqual(data_volume['emptyDir']['sizeLimit'], '2Gi')

        ingress = by_kind_name[('Ingress', 'higress-grafana')]
        self.assertEqual(ingress['spec']['ingressClassName'], 'higress')
        rule = ingress['spec']['rules'][0]
        self.assertEqual(rule['host'], 'ack.tokenvolt.net')
        self.assertEqual(rule['http']['paths'][0]['path'], '/grafana')

        provisioning = by_kind_name[('ConfigMap', 'higress-grafana-provisioning')]['data']
        self.assertIn('http://higress-metrics-collector.higress-system.svc:9090', provisioning['datasource.yaml'])
        self.assertIn('/var/lib/grafana/dashboards', provisioning['dashboards.yaml'])
        dashboard_data = by_kind_name[('ConfigMap', 'higress-grafana-dashboards')]['data']
        self.assertEqual(set(dashboard_data), {
            'tokenvolt-model-quality.json',
            'tokenvolt-runtime.json',
            'tokenvolt-infrastructure.json',
            'tokenvolt-request-details.json',
        })
        dashboard = json.loads(dashboard_data['tokenvolt-model-quality.json'])
        dashboard_json = json.dumps(dashboard)
        ranking = next(panel for panel in dashboard['panels'] if panel['id'] == 10)
        self.assertEqual(ranking['type'], 'table')
        self.assertEqual(ranking['transformations'][0]['id'], 'joinByLabels')
        self.assertEqual(ranking['transformations'][0]['options']['join'], ['public_ai_provider'])
        self.assertNotIn('route', {item['name'] for item in dashboard['templating']['list']})
        self.assertNotIn('p99', dashboard_json.lower())
        self.assertIn('tokenvolt:provider_model_identity:info', dashboard_json)
        self.assertIn('@ end()', dashboard_json)

        runtime = json.loads(dashboard_data['tokenvolt-runtime.json'])
        runtime_table = runtime['panels'][0]
        self.assertEqual(runtime_table['transformations'][0]['options']['join'],
                         ['public_ai_model', 'public_ai_provider'])
        self.assertNotIn('已配置', json.dumps(runtime_table))
        self.assertNotIn('route', {item['name'] for item in runtime['templating']['list']})
        self.assertNotIn('p99', json.dumps(runtime).lower())

        collector_data = by_kind_name[('ConfigMap', 'higress-metrics-collector')]['data']
        collector = collector_data['prometheus.yml']
        config = yaml.safe_load(collector)
        rules = collector_data['recording-rules.yml']
        self.assertIn('tokenvolt:provider_model_identity:info', rules)
        self.assertIn('group_left (public_ai_model,public_ai_provider)', rules)
        self.assertNotIn('p99_rate5m',
                         rules)
        self.assertNotIn('p99',
                         by_kind_name[('ConfigMap', 'higress-ack-promql')]['data'])
        gateway_scrape = next(job for job in config['scrape_configs']
                              if job['job_name'] == 'higress-gateway')
        gateway_relabels = gateway_scrape['metric_relabel_configs']
        self.assertIn(
            {'source_labels': ['cluster_name'], 'regex': '(.+)',
             'target_label': 'ai_provider', 'replacement': '$1'},
            gateway_relabels,
        )
        self.assertNotIn('envoy_cluster_name', collector)
        self.assertIn('rq_time_(bucket|sum|count)', collector)
        self.assertIn('upstream_rq_time_(bucket|sum|count)', collector)
        infrastructure = json.loads(dashboard_data['tokenvolt-infrastructure.json'])
        infrastructure_titles = {panel['title'] for panel in infrastructure['panels']}
        self.assertIn('Inbound / Outbound 活跃连接', infrastructure_titles)
        self.assertIn('下游 HTTP 总耗时 P50 / P90', infrastructure_titles)
        self.assertIn('上游异常事件 / 5 分钟', infrastructure_titles)
        self.assertNotIn(
            {'regex': '^ai_consumer$', 'action': 'labeldrop'},
            gateway_relabels,
        )
        self.assertIn(
            {'source_labels': ['ai_consumer'], 'regex': '.+', 'action': 'drop'},
            config['remote_write'][0]['write_relabel_configs'],
        )

        state_metrics = by_kind_name[('Deployment', 'higress-hpa-state-metrics')]
        state_metrics_args = state_metrics['spec']['template']['spec']['containers'][0]['args']
        annotation_allowlist = next(arg for arg in state_metrics_args
                                    if arg.startswith('--metric-annotations-allowlist='))
        self.assertIn('higress.io/destination', annotation_allowlist)


if __name__ == '__main__':
    unittest.main()
