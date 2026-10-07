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

"""Exercise actual billing variable validation without cloud credentials/providers."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def variable_block(name):
    source = (ROOT / "variables.tf").read_text()
    start = source.index('variable "' + name + '" {')
    depth = 0
    for pos in range(source.index("{", start), len(source)):
        depth += (source[pos] == "{") - (source[pos] == "}")
        if depth == 0:
            return source[start:pos + 1]
    raise AssertionError("unterminated variable")


class BillingConfigTest(unittest.TestCase):
    def test_real_validation_accepts_existing_policy_and_rejects_bad_combinations(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            directory.joinpath("main.tf").write_text("\n".join(variable_block(name) for name in ("tokenvolt_rds_billing", "tokenvolt_redis_billing")))
            for name, field, prepaid, postpaid in (
                ("tokenvolt_rds_billing", "instance_charge_type", "Prepaid", "Postpaid"),
                ("tokenvolt_redis_billing", "payment_type", "PrePaid", "PostPaid"),
            ):
                for value, valid in (
                    ({}, True),
                    ({field: prepaid, "auto_renew": True, "auto_renew_period": 1}, True),
                    ({field: prepaid, "auto_renew": False}, True),
                    ({field: "invalid"}, False),
                    ({field: postpaid, "auto_renew": True, "auto_renew_period": 1}, False),
                    ({field: prepaid, "auto_renew": True}, False),
                    ({field: prepaid, "auto_renew": True, "auto_renew_period": 0}, False),
                    ({field: prepaid, "auto_renew": True, "auto_renew_period": 13}, False),
                    ({field: prepaid, "auto_renew": True, "auto_renew_period": 1.5}, False),
                ):
                    with self.subTest(name=name, value=value):
                        result = subprocess.run(["tofu", "plan", "-no-color", "-input=false", "-refresh=false", "-lock=false", "-var=" + name + "=" + json.dumps(value)], cwd=directory, capture_output=True, text=True, timeout=30)
                        self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
