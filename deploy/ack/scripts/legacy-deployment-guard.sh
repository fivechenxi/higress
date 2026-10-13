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

# Per-command emergency escape hatch; do not put this in a shell profile or CI.
if test "${TOKENVOLT_LEGACY_DEPLOYMENT:-}" = approved-emergency; then
  exit 0
fi

printf '%s\n' \
  'Legacy TokenVolt deployment is disabled after the Helm ownership cutover.' \
  'Use TokenVolt-ai/tokenvolt-deploy; no cloud credentials or writes were attempted by this entry point.' \
  'For an explicitly approved recovery, read deploy/ack/LEGACY_DISABLED.md first.' >&2
exit 42
