# Include standard NID (NSO in Docker) package Makefile that defines all
# standard make targets
include nidpackage.mk

# The following are specific to this repositories packages
testenv-start-extra:
	@echo "Starting repository specific testenv"
# Start extra things, for example a netsim container by doing:
# docker run -td --name $(CNT_PREFIX)-my-netsim --network-alias mynetsim1 $(DOCKER_ARGS) $(IMAGE_PATH)my-netsim-image:$(DOCKER_TAG)
# Note how it becomes available under the name 'mynetsim1' from the NSO
# container, i.e. you can set the device address to 'mynetsim1' and it will
# magically work.

testenv-test:
	@echo "-- Cleaning out test data from CDB"
	$(MAKE) testenv-runcmd CMD="configure\n delete src\n commit"
	$(MAKE) testenv-runcmd CMD="configure\n delete dst\n commit"
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

