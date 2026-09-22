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

publish=false
if [[ ${1:-} == "--publish" ]]; then
  publish=true
elif [[ $# -ne 0 ]]; then
  printf 'Usage: %s [--publish]\n' "$0" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ack_dir=$(cd -- "$script_dir/.." && pwd)
repo_root=$(cd -- "$ack_dir/../.." && pwd)
manifest="$ack_dir/artifacts/ai-proxy.sh"
profile=${ALICLOUD_PROFILE:-tokenvolt}
region=${ALICLOUD_REGION:-cn-beijing}

# shellcheck source=../artifacts/ai-proxy.sh
source "$manifest"

git -C "$repo_root" cat-file -e "${AI_PROXY_SOURCE_COMMIT}^{commit}"
if ! git -C "$repo_root" merge-base --is-ancestor "$AI_PROXY_REQUIRED_FIX_COMMIT" "$AI_PROXY_SOURCE_COMMIT"; then
  printf 'Pinned ai-proxy source %s does not contain required SSE framing fix %s.\n' \
    "$AI_PROXY_SOURCE_COMMIT" "$AI_PROXY_REQUIRED_FIX_COMMIT" >&2
  exit 1
fi

artifact_dir="$ack_dir/.artifacts/ai-proxy"
artifact="$artifact_dir/${AI_PROXY_SHA256}.wasm"
mkdir -p "$artifact_dir"
tmpdir=""
remote_tmp=""

cleanup() {
  if [[ -n $tmpdir ]]; then
    rm -rf -- "$tmpdir"
  fi
  if [[ -n $remote_tmp ]]; then
    rm -f -- "$remote_tmp"
  fi
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_artifact() {
  local candidate=$1
  local actual_sha256
  [[ $(LC_ALL=C head -c 4 "$candidate" | od -An -tx1 | tr -d ' \n') == "0061736d" ]] || {
    printf '%s is not a Wasm module.\n' "$candidate" >&2
    return 1
  }
  actual_sha256=$(sha256_file "$candidate")
  if [[ $actual_sha256 != "$AI_PROXY_SHA256" ]]; then
    printf 'ai-proxy checksum mismatch: expected %s, got %s.\n' "$AI_PROXY_SHA256" "$actual_sha256" >&2
    return 1
  fi
}

if [[ -f $artifact ]]; then
  verify_artifact "$artifact"
else
  tmpdir=$(mktemp -d)
  git -C "$repo_root" archive "$AI_PROXY_SOURCE_COMMIT" plugins/wasm-go/extensions/ai-proxy | tar -x -C "$tmpdir"
  source_dir="$tmpdir/plugins/wasm-go/extensions/ai-proxy"
  candidate="$tmpdir/ai-proxy.wasm"
  (
    cd "$source_dir"
    # The provider package owns the SSE framing regression tests. The root
    # package's exhaustive proxy-host suite is intentionally left to Higress CI.
    env GOTOOLCHAIN="$AI_PROXY_GO_TOOLCHAIN" go test -count=1 ./provider
    env GOOS=wasip1 GOARCH=wasm CGO_ENABLED=0 GOTOOLCHAIN="$AI_PROXY_GO_TOOLCHAIN" \
      go build -trimpath -buildvcs=false -buildmode=c-shared -o "$candidate" .
  )
  verify_artifact "$candidate"
  mv "$candidate" "$artifact"
fi

printf 'Verified ai-proxy Wasm: %s\n' "$artifact"
printf 'Source commit: %s (includes SSE framing fix %s)\n' "$AI_PROXY_SOURCE_COMMIT" "$AI_PROXY_REQUIRED_FIX_COMMIT"
printf 'SHA-256: %s\n' "$AI_PROXY_SHA256"

if ! $publish; then
  printf 'Dry run only; no OSS object was created. Use --publish after release approval.\n'
  exit 0
fi

if [[ -n ${TOKENVOLT_PLUGIN_BUCKET:-} ]]; then
  bucket=$TOKENVOLT_PLUGIN_BUCKET
else
  account_id=$(aliyun sts GetCallerIdentity --profile "$profile" --region "$region" | jq -er '.AccountId')
  bucket="tokenvolt-plugins-${account_id}-${region}"
fi
object_uri="oss://${bucket}/${AI_PROXY_OBJECT_KEY}"

remote_tmp=$(mktemp)
if aliyun oss stat "$object_uri" --profile "$profile" --region "$region" >/dev/null 2>&1; then
  aliyun oss cp "$object_uri" "$remote_tmp" --profile "$profile" --region "$region" --force >/dev/null
  verify_artifact "$remote_tmp"
  printf 'Verified existing immutable ai-proxy object at %s\n' "$object_uri"
  exit 0
fi

aliyun oss cp "$artifact" "$object_uri" \
  --profile "$profile" \
  --region "$region" \
  --force \
  --acl public-read \
  --meta "Content-Type:application/wasm#Cache-Control:public,max-age=31536000,immutable#x-oss-meta-sha256:${AI_PROXY_SHA256}#x-oss-meta-source-commit:${AI_PROXY_SOURCE_COMMIT}"
aliyun oss cp "$object_uri" "$remote_tmp" --profile "$profile" --region "$region" --force >/dev/null
verify_artifact "$remote_tmp"
printf 'Uploaded and verified ai-proxy Wasm at %s\n' "$object_uri"
