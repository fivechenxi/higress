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

"""Exercise actual Pod termination in the isolated higress-drain-test namespace.

Requires drain_fixture.go running in Pod drain-fixture and an ingress for
Host drain.test. Never targets production or a real model provider.
"""
import argparse
import datetime as dt
import json
import subprocess
import time
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kubeconfig', required=True)
    parser.add_argument('--case', choices=['scale', 'rollout'], required=True)
    parser.add_argument('--seconds', type=int, default=40)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    if not 20 <= args.seconds <= 60:
        parser.error('--seconds must be between 20 and 60')
    kubectl = ['kubectl', '--kubeconfig', args.kubeconfig, '-n', 'higress-drain-test']

    def run(command):
        return subprocess.check_output(kubectl + command, text=True)

    run(['rollout', 'status', 'deployment/higress-gateway', '--timeout=120s'])
    pods = json.loads(run(['get', 'pods', '-l', 'app=higress-gateway', '-o', 'json']))['items']
    ready = [pod for pod in pods if not pod['metadata'].get('deletionTimestamp')
             and pod['status'].get('containerStatuses')
             and all(c.get('ready') for c in pod['status']['containerStatuses'])]
    if not ready:
        raise RuntimeError('No ready canary gateway')
    target = ready[0]
    name, ip = target['metadata']['name'], target['status']['podIP']
    case_id = uuid.uuid4().hex[:12]
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    clients = []
    expected_usage = {'prompt_tokens': 20, 'completion_tokens': 20, 'total_tokens': 40}
    with (output / 'gateway.log').open('w') as log_file:
        logs = subprocess.Popen(kubectl + ['logs', '-f', name], stdout=log_file,
                                stderr=subprocess.STDOUT, text=True)
        try:
            for mode in ['normal', 'stream']:
                request_id = f'drain-{case_id}-{mode}'
                # Run inside the cluster: kubectl port-forward itself dies with
                # the Pod and would falsely report a truncated response.
                client = subprocess.Popen(kubectl + ['exec', 'drain-fixture', '--',
                    '/tmp/drain-fixture', 'client', 'http://' + ip, mode,
                    request_id, str(args.seconds)], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True)
                clients.append((request_id, client))
            for _ in range(60):
                fixture_log = run(['logs', 'drain-fixture'])
                if all('START ' + rid in fixture_log for rid, _ in clients):
                    break
                time.sleep(.25)
            else:
                raise RuntimeError('Requests did not reach fixture; no termination triggered')
            trigger = dt.datetime.now(dt.timezone.utc).isoformat()
            if args.case == 'scale':
                run(['annotate', 'pod', name,
                     'controller.kubernetes.io/pod-deletion-cost=-1000', '--overwrite'])
                run(['scale', 'deployment/higress-gateway', f'--replicas={len(ready)-1}'])
            else:
                run(['rollout', 'restart', 'deployment/higress-gateway'])
            results = []
            for rid, client in clients:
                stdout, stderr = client.communicate(timeout=90)
                try:
                    result = json.loads(stdout)
                except ValueError:
                    result = {'id': rid, 'complete': False, 'stdout': stdout, 'stderr': stderr}
                result['exit_code'] = client.returncode
                results.append(result)
            logs.wait(timeout=45)
        finally:
            for _, client in clients:
                if client.poll() is None:
                    client.terminate()
                    client.communicate(timeout=5)
            if logs.poll() is None:
                logs.terminate()
                logs.wait(timeout=5)
    log_lines = (output / 'gateway.log').read_text().splitlines()
    access_logs = []
    for line in log_lines:
        if line.startswith('{'):
            try:
                access_logs.append(json.loads(line))
            except ValueError:
                pass
    # Envoy generates an upstream X-Request-Id. Correlate using the ID returned
    # by the fixture, not the untrusted client header.
    counts, usages = {}, {}
    for result in results:
        rid = result['id']
        matching = [row for row in access_logs
                    if row.get('request_id') == result.get('upstream_id')]
        counts[rid] = len(matching)
        usages[rid] = []
        for row in matching:
            try:
                usages[rid].append(json.loads(row.get('ai_log', '-')))
            except ValueError:
                pass
    summary = {'case': args.case, 'target_pod': name,
               'triggered_at': trigger, 'seconds': args.seconds, 'results': results,
               'access_log_counts': counts, 'logged_usage': usages,
               'drain_lines': [line for line in log_lines if any(marker in line for marker in
                   ['Agent draining', 'active connections', 'Graceful termination', 'tokenvolt drain:'])]}
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    assert all(r.get('complete') and r.get('usage') == expected_usage for r in results), \
        'In-flight request was truncated'
    assert set(counts.values()) == {1}, 'Missing/duplicate final access log'
    assert all(len(rows) == 1 and rows[0].get('usage_status') == 'complete'
               and [rows[0].get(k) for k in ['input_token', 'output_token', 'total_token']] == [20, 20, 40]
               for rows in usages.values()), 'Final usage missing or incorrect'
    assert any('Agent draining' in line for line in log_lines), 'Termination was not exercised'
    assert any('tokenvolt drain: active_requests=2' in line or 'There are still 2' in line
               for line in log_lines), 'No in-flight drain observed'
    assert any('There are no more active connections' in line for line in log_lines), \
        'Gateway did not exit after draining'


if __name__ == '__main__':
    main()
