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
	$(MAKE) testenv-runcmd CMD="configure\n delete a\n commit"
	$(MAKE) testenv-runcmd CMD="configure\n delete b\n commit"
	$(MAKE) testenv-runcmd CMD="configure\n set b a foobar\n commit"
	docker exec -t $(CNT_PREFIX)-nso bash -lc 'export PYTHONPATH=$$PYTHONPATH:/var/opt/ncs/packages/maagic-copy/python; python3 /var/opt/ncs/packages/test-maagic-copy/python/test_maagic_copy/main.py'
	$(MAKE) testenv-runcmd CMD="show configuration b" | grep foobar
