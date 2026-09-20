#!/usr/bin/env bash
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

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ack_dir=$(cd -- "$script_dir/.." && pwd)
manifest="$ack_dir/artifacts/grafana-sls-plugin.sh"
profile=${ALICLOUD_PROFILE:-tokenvolt}
region=${ALICLOUD_REGION:-cn-beijing}

# shellcheck source=../artifacts/grafana-sls-plugin.sh
source "$manifest"
version=$GRAFANA_SLS_PLUGIN_VERSION
source_url=$GRAFANA_SLS_PLUGIN_SOURCE_URL
object_key=$GRAFANA_SLS_PLUGIN_OBJECT_KEY
expected_sha256=$GRAFANA_SLS_PLUGIN_SHA256

if [[ -n ${TOKENVOLT_PLUGIN_BUCKET:-} ]]; then
  bucket=$TOKENVOLT_PLUGIN_BUCKET
else
  account_id=$(aliyun sts GetCallerIdentity --profile "$profile" --region "$region" | jq -er '.AccountId')
  bucket="tokenvolt-plugins-${account_id}-${region}"
fi
object_uri="oss://${bucket}/${object_key}"

if aliyun oss stat "$object_uri" --profile "$profile" --region "$region" >/dev/null 2>&1; then
  printf 'Grafana SLS datasource %s already exists at %s\n' "$version" "$object_uri"
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="$tmpdir/plugin.tar.gz"
curl --fail --location --retry 3 --output "$archive" "$source_url"

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
else
  actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
fi
if [[ $actual_sha256 != "$expected_sha256" ]]; then
  printf 'Checksum mismatch: expected %s, got %s\n' "$expected_sha256" "$actual_sha256" >&2
  exit 1
fi

aliyun oss cp "$archive" "$object_uri" \
  --profile "$profile" \
  --region "$region" \
  --force \
  --acl public-read \
  --meta "Content-Type:application/gzip#Cache-Control:public,max-age=31536000,immutable#x-oss-meta-sha256:${expected_sha256}"
printf 'Uploaded Grafana SLS datasource %s to %s\n' "$version" "$object_uri"
