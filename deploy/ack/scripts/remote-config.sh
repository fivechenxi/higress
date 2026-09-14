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
CONFIG_FILE="$ACK_DIR/terraform.tfvars"
SYNC_FILE="$ACK_DIR/.terraform/tfvars-sync.sha256"
REMOTE_FILE="$ACK_DIR/remote-config.hcl"
ACTION=${1:-status}
FORCE=${2:-}

test -f "$REMOTE_FILE" || {
  printf 'Missing remote-config.hcl.\n' >&2
  exit 1
}
command -v aliyun >/dev/null

hcl_value() {
  awk -v key="$1" '$1 == key && $2 == "=" {gsub(/^"|"$/, "", $3); print $3; exit}' "$REMOTE_FILE"
}

BUCKET=$(hcl_value bucket)
OBJECT_KEY=$(hcl_value key)
REGION=$(hcl_value region)
PROFILE=$(hcl_value profile)
test -n "$BUCKET" && test -n "$OBJECT_KEY" && test -n "$REGION" && test -n "$PROFILE"
REMOTE_URI="oss://$BUCKET/$OBJECT_KEY"
TMP_FILE=$(mktemp)
ERROR_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE" "$ERROR_FILE"' EXIT HUP INT TERM

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

remote_fetch() {
  : >"$TMP_FILE"
  : >"$ERROR_FILE"
  if aliyun oss cp "$REMOTE_URI" "$TMP_FILE" --force --profile "$PROFILE" --region "$REGION" >/dev/null 2>"$ERROR_FILE"; then
    return 0
  fi
  if grep -Eq 'StatusCode=404|ErrorCode=NoSuchKey' "$ERROR_FILE"; then
    return 1
  fi
  printf 'Failed to read remote tfvars:\n' >&2
  sed -n '1,8p' "$ERROR_FILE" >&2
  return 2
}

base_hash() {
  test -f "$SYNC_FILE" && tr -d '[:space:]' <"$SYNC_FILE" || true
}

save_base() {
  umask 077
  mkdir -p "$(dirname -- "$SYNC_FILE")"
  printf '%s\n' "$1" >"$SYNC_FILE"
}

status() {
  LOCAL_HASH="missing"
  REMOTE_HASH="missing"
  BASE_HASH=$(base_hash)
  test -f "$CONFIG_FILE" && LOCAL_HASH=$(file_hash "$CONFIG_FILE")
  if remote_fetch; then
    REMOTE_HASH=$(file_hash "$TMP_FILE")
  else
    FETCH_STATUS=$?
    test "$FETCH_STATUS" -eq 1 || exit "$FETCH_STATUS"
  fi

  STATE=conflict
  if test "$LOCAL_HASH" = "$REMOTE_HASH" && test "$LOCAL_HASH" != missing; then
    STATE=synchronized
  elif test "$REMOTE_HASH" = missing && test "$LOCAL_HASH" != missing; then
    STATE=local-only
  elif test "$LOCAL_HASH" = missing && test "$REMOTE_HASH" != missing; then
    STATE=remote-only
  elif test -n "$BASE_HASH" && test "$REMOTE_HASH" = "$BASE_HASH"; then
    STATE=local-changed
  elif test -n "$BASE_HASH" && test "$LOCAL_HASH" = "$BASE_HASH"; then
    STATE=remote-changed
  fi
  printf 'state=%s\nlocal=%s\nremote=%s\nbase=%s\n' "$STATE" "$LOCAL_HASH" "$REMOTE_HASH" "${BASE_HASH:-missing}"
}

pull() {
  PULL_FORCE=${1:-$FORCE}
  if remote_fetch; then
    :
  else
    FETCH_STATUS=$?
    if test "$FETCH_STATUS" -eq 1; then printf 'Remote tfvars does not exist: %s\n' "$REMOTE_URI" >&2; fi
    exit "$FETCH_STATUS"
  fi
  REMOTE_HASH=$(file_hash "$TMP_FILE")
  BASE_HASH=$(base_hash)
  if test -f "$CONFIG_FILE" && test "$PULL_FORCE" != --force; then
    LOCAL_HASH=$(file_hash "$CONFIG_FILE")
    if test "$LOCAL_HASH" != "$REMOTE_HASH" && { test -z "$BASE_HASH" || test "$LOCAL_HASH" != "$BASE_HASH"; }; then
      printf 'Refusing to overwrite locally changed terraform.tfvars; resolve it or use --force.\n' >&2
      exit 1
    fi
  fi
  umask 077
  cp "$TMP_FILE" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  save_base "$REMOTE_HASH"
  printf 'Pulled %s\n' "$REMOTE_URI"
}

push() {
  PUSH_FORCE=${1:-$FORCE}
  test -f "$CONFIG_FILE" || { printf 'Missing terraform.tfvars.\n' >&2; exit 1; }
  chmod 600 "$CONFIG_FILE"
  LOCAL_HASH=$(file_hash "$CONFIG_FILE")
  BASE_HASH=$(base_hash)
  if remote_fetch; then
    REMOTE_HASH=$(file_hash "$TMP_FILE")
    if test "$REMOTE_HASH" = "$LOCAL_HASH"; then
      save_base "$LOCAL_HASH"
      printf 'Already synchronized.\n'
      return
    fi
    if test "$PUSH_FORCE" != --force && { test -z "$BASE_HASH" || test "$REMOTE_HASH" != "$BASE_HASH"; }; then
      printf 'Remote tfvars changed since the last sync; pull and merge before pushing.\n' >&2
      exit 1
    fi
  else
    FETCH_STATUS=$?
    test "$FETCH_STATUS" -eq 1 || exit "$FETCH_STATUS"
  fi
  aliyun oss cp "$CONFIG_FILE" "$REMOTE_URI" --force --profile "$PROFILE" --region "$REGION" >/dev/null
  remote_fetch
  test "$(file_hash "$TMP_FILE")" = "$LOCAL_HASH"
  save_base "$LOCAL_HASH"
  printf 'Pushed encrypted, versioned %s\n' "$REMOTE_URI"
}

prepare() {
  if ! test -f "$CONFIG_FILE"; then pull; return; fi
  if remote_fetch; then
    :
  else
    FETCH_STATUS=$?
    if test "$FETCH_STATUS" -eq 1; then
      printf 'Remote tfvars is absent; keeping the local file.\n'
      return
    fi
    exit "$FETCH_STATUS"
  fi
  LOCAL_HASH=$(file_hash "$CONFIG_FILE")
  REMOTE_HASH=$(file_hash "$TMP_FILE")
  BASE_HASH=$(base_hash)
  if test "$LOCAL_HASH" = "$REMOTE_HASH"; then save_base "$LOCAL_HASH"; return; fi
  if test -n "$BASE_HASH" && test "$LOCAL_HASH" = "$BASE_HASH"; then pull --force; return; fi
  if test -n "$BASE_HASH" && test "$REMOTE_HASH" = "$BASE_HASH"; then
    printf 'Using locally changed terraform.tfvars; it will be pushed only after a successful apply.\n'
    return
  fi
  printf 'Both local and remote tfvars changed; resolve the conflict before deploying.\n' >&2
  exit 1
}

case "$ACTION" in
  status) status ;;
  pull) pull ;;
  push) push ;;
  prepare) prepare ;;
  history) aliyun oss ls "$REMOTE_URI" --all-versions --profile "$PROFILE" --region "$REGION" ;;
  *) printf 'Usage: %s {status|pull|push|prepare|history} [--force]\n' "$0" >&2; exit 2 ;;
esac
