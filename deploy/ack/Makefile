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
