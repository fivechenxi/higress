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

TOFU ?= tofu

.PHONY: init plan start stop destroy

init:
	$(TOFU) init

plan:
	$(TOFU) plan

start:
	$(TOFU) apply -auto-approve -var='lifecycle_mode=starting'
	$(TOFU) apply -auto-approve -var='lifecycle_mode=running'

stop:
	$(TOFU) apply -auto-approve -var='lifecycle_mode=stopping'
	$(TOFU) apply -auto-approve -var='lifecycle_mode=stopped'

destroy:
	$(TOFU) destroy
