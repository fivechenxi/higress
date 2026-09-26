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

"""Contract checks for the lightweight single-replica TokenVolt site."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1] / "charts/tokenvolt"


def render(enabled=True):
    values = {
        "controlPlane": {
            "image": "example.invalid/control-plane@sha256:" + "a" * 64,
            "rrsaRoleName": "fixture-role",
            "cloud": dict.fromkeys(
                ["slsRegionId", "slsEndpoint", "slsProject", "slsLogstore",
                 "ossRegionId", "ossEndpoint", "ossBucket"], "fixture"
            ),
        },
        "higress": {
            "policyPluginUrl": "oci://example.invalid/policy@sha256:" + "b" * 64,
            "aiStatistics": {
                "pluginUrl": "https://example.invalid/stats.wasm",
                "pluginSha256": "c" * 64,
            },
            "rateLimits": {"enabled": False},
        },
        "site": {
            "enabled": enabled,
            "image": "ghcr.io/example/site@sha256:" + "d" * 64,
            "publicService": {
                "enabled": enabled,
                "annotations": {
                    "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id": "lb-shared",
                    "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners": "false",
                    "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-vgroup-port": "rsp-site:4192",
                    "service.beta.kubernetes.io/backend-type": "eni",
                },
            },
        },
    }
    with tempfile.NamedTemporaryFile(mode="w") as stream:
        json.dump(values, stream)
        stream.flush()
        result = subprocess.run(
            ["helm", "template", "tokenvolt", str(CHART), "--namespace",
             "tokenvolt-system", "-f", stream.name],
            capture_output=True, text=True,
        )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


class TokenVoltSiteTest(unittest.TestCase):
    def test_site_is_disabled_by_default(self):
        self.assertFalse(any(obj["metadata"]["name"].startswith("tokenvolt-site")
                             for obj in render(False)))

    def test_site_has_one_recreate_replica_and_persistent_sqlite(self):
        objects = render()
        deployment = next(obj for obj in objects if obj["kind"] == "Deployment"
                          and obj["metadata"]["name"] == "tokenvolt-site")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertEqual(deployment["spec"]["strategy"], {"type": "Recreate"})
        pod = deployment["spec"]["template"]["spec"]
        self.assertEqual(pod["securityContext"]["fsGroup"], 10001)
        container = pod["containers"][0]
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/api/health")
        self.assertEqual(container["livenessProbe"]["httpGet"]["path"], "/api/health")
        self.assertIn({"name": "data", "mountPath": "/var/lib/tokenvolt"},
                      container["volumeMounts"])

        claim = next(obj for obj in objects if obj["kind"] == "PersistentVolumeClaim")
        self.assertEqual(claim["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        self.assertEqual(claim["spec"]["storageClassName"], "tokenvolt-retain-disk")
        self.assertEqual(claim["spec"]["resources"]["requests"]["storage"], "20Gi")

    def test_public_service_reuses_clb_without_listener_ownership(self):
        service = next(obj for obj in render() if obj["kind"] == "Service"
                       and obj["metadata"]["name"] == "tokenvolt-site")
        self.assertEqual(service["spec"]["type"], "LoadBalancer")
        self.assertEqual(service["spec"]["ports"][0]["port"], 4192)
        annotations = service["metadata"]["annotations"]
        self.assertEqual(annotations[
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners"
        ], "false")
        self.assertEqual(annotations[
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-vgroup-port"
        ], "rsp-site:4192")


if __name__ == "__main__":
    unittest.main()
