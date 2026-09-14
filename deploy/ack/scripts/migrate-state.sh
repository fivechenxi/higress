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

ACK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOFU=${TOFU:-./scripts/tofu.sh}
cd "$ACK_DIR"

if test -f terraform.tfstate; then
  BACKUP="terraform.tfstate.pre-oss-$(date -u +%Y%m%dT%H%M%SZ)"
  cp terraform.tfstate "$BACKUP"
  chmod 600 "$BACKUP"
  printf 'Created recovery copy: %s\n' "$BACKUP"
fi

"$TOFU" init -migrate-state -force-copy
"$TOFU" state pull >/dev/null

if test -f terraform.tfvars; then
  ./scripts/remote-config.sh push --force
fi

printf 'OSS state migration verified with tofu state pull.\n'
