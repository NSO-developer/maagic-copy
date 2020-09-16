# You can set the default NSO_IMAGE_PATH & PKG_PATH to point to your docker
# registry so that developers don't have to manually set these variables.
# Similarly for NSO_VERSION you can set a default version. Note how the ?=
# operator only sets these variables if not already set, thus you can easily
# override them by explicitly setting them in your environment and they will be
# overridden by variables in CI.
# TODO: uncomment and fill in values for your environment
# Default variables:
#export NSO_IMAGE_PATH ?= registry.example.com:5000/my-group/nso-docker/
#export PKG_PATH ?= registry.example.com:5000/my-group/
#export NSO_VERSION ?= 5.4

# Include standard NID (NSO in Docker) package Makefile that defines all
# standard make targets
include nidpackage.mk

# The rest of this file is specific to this repository.

testenv-start-extra:
	@echo "\n== Starting repository specific testenv"


testenv-test:
	@echo "-- Cleaning out test data from CDB"
	$(MAKE) testenv-runcmdJ CMD="configure\n delete src\n commit"
	$(MAKE) testenv-runcmdJ CMD="configure\n delete dst\n commit"
	@echo "-- Loading test data"
	$(MAKE) testenv-loadconf FILE="test/input/simple.xml"
	@echo "-- Running maagic_copy(src, dst)"
	docker exec -t $(CNT_PREFIX)-nso bash -lc 'export PYTHONPATH=$$PYTHONPATH:/var/opt/ncs/packages/maagic-copy/python; python3 /var/opt/ncs/packages/test-maagic-copy/python/test_maagic_copy/main.py'
	@echo "-- Saving output data"
	$(MAKE) testenv-saveconfxml FILE="test/output/simple-src.xml" CONFPATH="src simple"
	$(MAKE) testenv-saveconfxml FILE="test/output/simple-dst.xml" CONFPATH="dst simple"
	@echo "-- Mangling data"
	xmlstarlet edit -O -N c=http://tail-f.com/ns/config/1.0 -N x=http://example.com/test-maagic-copy --move "/c:config/x:src/x:simple" "/" --delete "/c:config" test/output/simple-src.xml > test/output/simple-mangled-src.xml
	xmlstarlet edit -O -N c=http://tail-f.com/ns/config/1.0 -N x=http://example.com/test-maagic-copy --move "/c:config/x:dst/x:simple" "/" --delete "/c:config" test/output/simple-dst.xml > test/output/simple-mangled-dst.xml
	@echo "-- Comparing src to dst"
	diff -u test/output/simple-mangled-src.xml test/output/simple-mangled-dst.xml


testenv-loadconf:
	@if [ -z "$(FILE)" ]; then echo "FILE variable must be set"; false; fi
	@echo "Loading configuration $(FILE)"
	@docker exec -t $(CNT_PREFIX)-nso bash -lc "mkdir -p test/$(shell echo $(FILE) | xargs dirname)"
	@docker cp $(FILE) $(CNT_PREFIX)-nso:test/$(FILE)
	@$(MAKE) testenv-runcmdJ CMD="configure\nload merge test/$(FILE)\ncommit"


testenv-saveconfxml:
	@if [ -z "$(FILE)" ]; then echo "FILE variable must be set"; false; fi
	@echo "Saving configuration to $(FILE)"
	docker exec -t $(CNT_PREFIX)-nso bash -lc "mkdir -p test/$(shell echo $(FILE) | xargs dirname)"
	@$(MAKE) testenv-runcmdJ CMD="show configuration $(CONFPATH) | display xml | save test/$(FILE)"
	@docker cp $(CNT_PREFIX)-nso:test/$(FILE) $(FILE)
