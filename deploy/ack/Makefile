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

TOFU ?= ./scripts/tofu.sh
CONFIG_SYNC ?= ./scripts/remote-config.sh
ARTIFACT_SYNC ?= ./scripts/sync-artifacts.sh

.PHONY: backend-bootstrap backend-migrate init config-pull config-push config-status config-history artifacts-sync plan start stop destroy

backend-bootstrap:
	./scripts/bootstrap-backend.sh

backend-migrate:
	./scripts/migrate-state.sh

init:
	$(TOFU) init

config-pull:
	$(CONFIG_SYNC) pull

config-push:
	$(CONFIG_SYNC) push

config-status:
	$(CONFIG_SYNC) status

config-history:
	$(CONFIG_SYNC) history

artifacts-sync:
	$(ARTIFACT_SYNC)

plan:
	$(CONFIG_SYNC) prepare
	$(TOFU) plan

start: artifacts-sync
	$(CONFIG_SYNC) prepare
	$(TOFU) apply -auto-approve -var='lifecycle_mode=starting'
	$(TOFU) apply -auto-approve -var='lifecycle_mode=running'
	$(CONFIG_SYNC) push

stop:
	$(CONFIG_SYNC) prepare
	$(TOFU) apply -auto-approve -var='lifecycle_mode=stopping'
	$(TOFU) apply -auto-approve -var='lifecycle_mode=stopped'
	$(CONFIG_SYNC) push

destroy:
	$(CONFIG_SYNC) prepare
	$(TOFU) destroy
