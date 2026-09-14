#!/usr/bin/env sh
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

set -eu

TOFU_BIN=${TOFU_BIN:-tofu}
PROFILE=${ALICLOUD_PROFILE:-tokenvolt}

# OSS terraform.tfvars is the deployment source of truth. Protect direct
# tofu.sh plan/apply/destroy calls as well as the Makefile entry points so a
# stale local file cannot silently roll an ACK workload back. Bootstrap
# invocations use -chdir and deliberately manage a different state/config.
NEEDS_CONFIG_GUARD=false
SKIP_CONFIG_GUARD=false
for ARG in "$@"; do
  case "$ARG" in
    -chdir=*) SKIP_CONFIG_GUARD=true ;;
    plan|apply|destroy) NEEDS_CONFIG_GUARD=true ;;
  esac
done
if test "$NEEDS_CONFIG_GUARD" = true && test "$SKIP_CONFIG_GUARD" = false; then
  "$(dirname -- "$0")/remote-config.sh" prepare
fi

# The Alibaba Cloud provider understands CLI OAuth profiles, while OpenTofu's
# OSS backend expects standard AK/STS environment variables. Export the current
# short-lived credentials without printing or persisting them.
if test -z "${ALICLOUD_ACCESS_KEY_ID:-}" || test -z "${ALICLOUD_ACCESS_KEY_SECRET:-}"; then
  command -v aliyun >/dev/null
  command -v jq >/dev/null
  CREDENTIALS=$(aliyun configure get --profile "$PROFILE")
  ALICLOUD_ACCESS_KEY_ID=$(printf '%s' "$CREDENTIALS" | jq -er .access_key_id)
  ALICLOUD_ACCESS_KEY_SECRET=$(printf '%s' "$CREDENTIALS" | jq -er .access_key_secret)
  ALICLOUD_SECURITY_TOKEN=$(printf '%s' "$CREDENTIALS" | jq -r '.sts_token // empty')
  export ALICLOUD_ACCESS_KEY_ID ALICLOUD_ACCESS_KEY_SECRET ALICLOUD_SECURITY_TOKEN
  unset CREDENTIALS
fi

exec "$TOFU_BIN" "$@"
