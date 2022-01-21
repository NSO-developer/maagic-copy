include ../testenv-common.mk

# Enable IPv6 per default, set to false to disable (in Makefile, not here)
IPV6?=true
# start: start the test environment in a configuration that allows
# Python Remote Debugging. Exposes port 5678 on a random port on localhost.
# Per default, the IPv6 prefix is a randomly generated IPv6 network prefix in
# the ULA address space. Override by setting IPV6_NET variable to e.g.:
# IPV6_NET=2001:db8:1234:456:  # which becomes 2001:db8:1234:456::/64
# If the IPv6 prefix is not in the public unicast space (2000::/3), the IPv6
# default route will be removed. This makes it possible to have local IPv6
# connectivity within the network, yet not slow down attempts to reach Internet
# resources (where IPv6 would normally be tried first, and fail due to
# non-public addresses).
start:
	docker network inspect $(CNT_PREFIX) >/dev/null 2>&1 || docker network create $(CNT_PREFIX) $(shell [ "$(IPV6)" = "true" ] && export LC_ALL=C && echo --ipv6 --subnet $${IPV6_NET:-fd00:$$(< /dev/urandom tr -dc a-f0-9 | head -c4):$$(< /dev/urandom tr -dc a-f0-9 | head -c4):$$(< /dev/urandom tr -dc a-f0-9 | head -c4):}:/64)
	docker run -td --name $(CNT_PREFIX)-nso --network-alias nso $(DOCKER_NSO_ARGS) $(IMAGE_PATH)$(PROJECT_NAME)/testnso:$(DOCKER_TAG)
# You may start other containers that are part of the testenv here. For example
# a netsim container or a virtual router.
	-[ "$(IPV6)" = "true" ] && echo $$(docker network inspect --format '{{range .IPAM.Config}}{{- if (gt (split .Subnet ":"|len) 1) -}}{{.Subnet}}{{- end}}{{end}}' $(CNT_PREFIX)) | egrep "^[23]...:" || (echo "Removing IPv6 default route" && docker ps -aq --filter label=com.cisco.nso.testenv.name=$(CNT_PREFIX) | $(XARGS) -I CNT -n1 docker run --rm --net=container:CNT --cap-add=NET_ADMIN $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION) ip -6 route del default >/dev/null 2>&1 || true)

	$(MAKE) wait-started-nso

# Place your tests in test. Feel free to define a target per test case
# and call them from test in case you have more than a handful of cases.
# Sometimes when there is a "setup" or "preparation" part of a test, it can be
# useful to separate into its own target as to make it possible to run that
# prepare phase and then manually inspect the state of the system. You can
# achieve this by further refining the make targets you have.
test:
	@echo "\n== Running tests"
	@echo "-- Verify packages are operationally up"
	$(MAKE) runcmdJ CMD="show packages" | docker run -i --rm $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION) bash -c '! grep -P "oper-status (?!up)" >/dev/null' || (echo "ERROR: packages not operationally up:" && $(MAKE) runcmdJ CMD="show packages" && false)

	@echo "-- Cleaning out test data from CDB"
	$(MAKE) runcmdJ CMD="configure\n delete src\n delete dst\n commit"
	@echo "-- Loading test data"
	$(MAKE) loadconf FILE="test/input/simple.xml"
	@echo "-- Running maagic_copy(src, dst)"
	docker exec -t $(CNT_PREFIX)-nso bash -lc 'export PYTHONPATH=$$PYTHONPATH:/var/opt/ncs/packages/maagic-copy/python; python3 /var/opt/ncs/packages/test-maagic-copy/python/test_maagic_copy/main.py'
	@echo "-- Saving output data"
	$(MAKE) saveconfxml FILE="test/output/simple-src.xml" CONFPATH="src simple"
	$(MAKE) saveconfxml FILE="test/output/simple-dst.xml" CONFPATH="dst simple"
	@echo "-- Mangling data"
	xmlstarlet edit -O -N c=http://tail-f.com/ns/config/1.0 -N x=http://example.com/test-maagic-copy --move "/c:config/x:src/x:simple" "/" --delete "/c:config" test/output/simple-src.xml > test/output/simple-mangled-src.xml
	xmlstarlet edit -O -N c=http://tail-f.com/ns/config/1.0 -N x=http://example.com/test-maagic-copy --move "/c:config/x:dst/x:simple" "/" --delete "/c:config" test/output/simple-dst.xml > test/output/simple-mangled-dst.xml
	@echo "-- Comparing src to dst"
	diff -u test/output/simple-mangled-src.xml test/output/simple-mangled-dst.xml
	@echo "-- Executing /test-action"
	$(MAKE) runcmdJ CMD="request src test-action simple { test-when { condition foo condition2 a addition addition2 } } | display xml" | grep addition2
