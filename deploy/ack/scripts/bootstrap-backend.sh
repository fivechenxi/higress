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

BOOTSTRAP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../backend-bootstrap" && pwd)
TOFU=${TOFU:-./scripts/tofu.sh}

command -v "$TOFU" >/dev/null
"$TOFU" -chdir="$BOOTSTRAP_DIR" init
# These immutable bootstrap resources are checked against their local bootstrap
# state. Avoid a slow OSS refresh on every workstation setup; explicit drift
# inspection can still be run from backend-bootstrap when required.
"$TOFU" -chdir="$BOOTSTRAP_DIR" apply -auto-approve -refresh=false
printf 'Persistent OSS backend and TableStore lock are ready.\n'
