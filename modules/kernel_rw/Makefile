ROOT := $(abspath $(CURDIR)/../..)
MODULE := kernel_rw

.PHONY: all module user clean
all: module user

module:
	bash "$(ROOT)/scripts/build_external_module.sh" "$(MODULE)"

user:
	bash "$(ROOT)/scripts/build_user.sh" "$(MODULE)"

clean:
	bash "$(ROOT)/scripts/clean.sh" build
