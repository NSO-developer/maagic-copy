# Common Makefile for NSO in Docker package standard form.
#
# A repository that follows the standard form for a NID (NSO in Docker) package
# repository contains one or more NSO packages in the `/packages` directory.
# These packages, in their compiled form, are the primary output artifacts of
# the repository. In order to test the functionality of the packages, as part of
# the test make target, an NSO instance is started with the packages loaded. To
# enable actual testing, extra test-packages are loaded from the
# `/test-packages` folder. test-packages are not part of the primary output
# artifacts and are thus only included in the Docker image used for testing.
#
# The test environment, called testenv, assumes that a Docker image has already
# been built that contains the primary package artifacts and any necessary
# test-packages. Changing any package or test-packages would in normal Docker
# operations typically involve rebuilding the Docker image and restarting the
# entire testenv, however, an optimized procedure is available; NSO containers
# in the testenv are started with the packages directory on a volume which
# allows the testenv-build job to mount this directory, copy in the updated
# source code onto the volume, recompile the code and then reload it in NSO.
# This drastically reduces the length of the REPL loop and thus improves the
# environment for the developer.

# Determine our project name, either from CI_PROJECT_NAME which is normally set
# by GitLab CI or by looking at the name of our directory (that we are in).
ifneq ($(CI_PROJECT_NAME),)
PROJECT_NAME=$(CI_PROJECT_NAME)
else
PROJECT_NAME:=$(shell basename $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))))
endif

include nidcommon.mk

all:
	$(MAKE) build
	$(MAKE) test

test:
	$(MAKE) testenv-start
	$(MAKE) testenv-test
	$(MAKE) testenv-stop


Dockerfile: Dockerfile.in $(wildcard includes/*)
	@echo "-- Generating Dockerfile"
# Expand variables before injecting them into the Dockerfile as otherwise we
# would have to pass all the variables as build-args which makes this much
# harder to do in a generic manner. This works across GNU and BSD awk.
	cp Dockerfile.in Dockerfile
	for DEP_NAME in $$(ls includes/); do export DEP_URL=$$(awk '{ print "echo", $$0 }' includes/$${DEP_NAME} | $(SHELL) -); awk "/DEP_END/ { print \"FROM $${DEP_URL} AS $${DEP_NAME}\" }; /DEP_INC_END/ { print \"COPY --from=$${DEP_NAME} /var/opt/ncs/packages/ /var/opt/ncs/packages/\" }; 1" Dockerfile > Dockerfile.tmp; mv Dockerfile.tmp Dockerfile; done

# Dockerfile is defined as a PHONY target which means it will always be rebuilt.
# As the build of the Dockerfile relies on environment variables which we have
# no way of getting a timestamp for, we must rebuild in order to be safe.
.PHONY: Dockerfile


build: check-nid-available Dockerfile
	docker build --target testnso -t $(IMAGE_PATH)$(PROJECT_NAME)/testnso:$(DOCKER_TAG) --build-arg NSO_IMAGE_PATH=$(NSO_IMAGE_PATH) --build-arg NSO_VERSION=$(NSO_VERSION) --build-arg PKG_FILE=$(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG) .
	docker build --target package -t $(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG) --build-arg NSO_IMAGE_PATH=$(NSO_IMAGE_PATH) --build-arg NSO_VERSION=$(NSO_VERSION) --build-arg PKG_FILE=$(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG) .

push:
	docker push $(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG)

tag-release:
	docker tag $(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG) $(IMAGE_PATH)$(PROJECT_NAME)/package:$(NSO_VERSION)

push-release:
	docker push $(IMAGE_PATH)$(PROJECT_NAME)/package:$(NSO_VERSION)


dev-shell:
	docker run -it -v $$(pwd):/src $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION)

# Test environment targets

testenv-start:
	docker network inspect $(CNT_PREFIX) >/dev/null 2>&1 || docker network create $(CNT_PREFIX)
	docker run -td --name $(CNT_PREFIX)-nso --network-alias nso $(DOCKER_NSO_ARGS) -e ADMIN_PASSWORD=NsoDocker1337 $${NSO_EXTRA_ARGS} $(IMAGE_PATH)$(PROJECT_NAME)/testnso:$(DOCKER_TAG)
	$(MAKE) testenv-start-extra
	docker exec -t $(CNT_PREFIX)-nso bash -lc 'ncs --wait-started 600'

# testenv-build - recompiles and loads new packages in NSO
# Compilation happens in a cisco-nso-dev container that attaches up the running
# containers package directory as a volume. The source files are then copied
# over using rsync. The rsync operation is analyzed (by looking at the log) to
# determine what files were updated and based on that either reload all package
# or selectively redeploy individual packages. ENG-20488, released in NSO 5.3,
# made large improvements to package redeploy, before it, changes configuration
# template required a package reload. We take this into account by first looking
# at the NSO version. Note how the package name can be different from the
# package directory name, thus we use xmlstarlet to get the package name from
# package-meta-data.xml. A full package reload can be forced by setting
# PACKAGE_RELOAD to anything non-empty.
#
# build-meta-data.xml is also generated for packages that do not ship / build
# one themselves. Note how NSO only reads in build-meta-data.xml on package
# *reload*. A package *redeploy* will thus lead to a stale view in NSO.
SUPPORTS_NEW_REDEPLOY=$(shell if [ $(NSO_VERSION_MAJOR) -gt 5 ] || [ $(NSO_VERSION_MAJOR) -eq 5 -a $(NSO_VERSION_MINOR) -ge 3 ]; then echo "true"; fi)
ifeq ($(SUPPORTS_NEW_REDEPLOY),true)
RELOAD_PATTERN="(package-meta-data.xml|\.cli$$|\.yang$$)"
else
RELOAD_PATTERN="(package-meta-data.xml|templates/.*\.xml$$|\.cli$$|\.yang$$)"
endif
testenv-build:
	for NSO in $$(docker ps --format '{{.Names}}' --filter label=$(CNT_PREFIX) --filter label=nidtype=nso); do \
		echo "-- Rebuilding for NSO: $${NSO}"; \
		mkdir -p tmp && \
		docker run -it --rm -v $(PWD):/src --volumes-from $${NSO} -e PKG_FILE=$(IMAGE_PATH)$(PROJECT_NAME)/package:$(DOCKER_TAG) $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION) bash -lc 'rsync -aEim /src/packages/. /src/test-packages/. /var/opt/ncs/packages/ > /src/tmp/rsync.log; chown $$(stat -c "%u:%g" /src/tmp) /src/tmp/rsync.log 2>/dev/null; for PKG_DIR in $$(find /src/packages /src/test-packages -mindepth 1 -maxdepth 1 -type d); do export PKG_NAME=$$(basename $${PKG_DIR}); make -C /var/opt/ncs/packages/$${PKG_NAME}/src; OUTPUT_PATH=/var/opt/ncs/packages/$${PKG_NAME}/ make -f /src/nid/bmd.mk -C $${PKG_DIR} build-meta-data.xml; done' && \
		egrep $(RELOAD_PATTERN) tmp/rsync.log >/dev/null; if [ $$? -eq 0 ] || [ -n "$$PACKAGE_RELOAD" ]; then \
			echo "-- Reloading packages for NSO $${NSO}"; \
			$(MAKE) testenv-runcmdJ CMD="request packages reload force"; \
		else \
			for PKG in $$(sed 's,^[^ ]\+ \([^/]\+\).*,\1,' tmp/rsync.log | sort | uniq); do \
				echo "-- Redeploying package $${PKG} for NSO $${NSO}"; \
				PMD_FILE=$$(ls packages/$${PKG}/package-meta-data.xml packages/$${PKG}/src/package-meta-data.xml.in test-packages/$${PKG}/package-meta-data.xml test-packages/$${PKG}/src/package-meta-data.xml.in 2>/dev/null | head -n1); \
				PKG_NAME=$$(xmlstarlet sel -N x=http://tail-f.com/ns/ncs-packages -t -v "/x:ncs-package/x:name" -nl $${PMD_FILE}) && \
				$(MAKE) testenv-runcmdJ CMD="request packages package $${PKG_NAME} redeploy"; \
			done; \
		fi; \
		rm -rf tmp; \
	done

# testenv-clean-build - clean and rebuild from scratch
# We rsync (with --delete) in sources, which effectively is a superset of 'make
# clean' per package, as this will delete any built packages as well as removing
# old sources files that no longer exist.
testenv-clean-build:
	for NSO in $$(docker ps --format '{{.Names}}' --filter label=$(CNT_PREFIX) --filter label=nidtype=nso); do \
		echo "-- Cleaning NSO: $${NSO}"; \
		docker run -it --rm -v $(PWD):/src --volumes-from $${NSO} $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION) bash -lc 'rsync -aEim --delete /src/packages/. /src/test-packages/. /var/opt/ncs/packages/ >/dev/null'; \
	done
	@echo "-- Done cleaning, rebuilding with forced package reload..."
	$(MAKE) testenv-build PACKAGE_RELOAD="true"

# testenv-stop - stop the testenv
# This finds the currently running containers that are part of our testenv based
# on their labels and then stops them, finally removing the docker network too.
# All containers that are part of our testenv must be started with the correct
# labels for this to work correctly. Use the variables DOCKER_ARGS or
# DOCKER_NSO_ARGS when running 'docker run', see testenv-start.
testenv-stop:
	docker ps -aq --filter label=$(CNT_PREFIX) | $(XARGS) docker rm -vf
	-docker network rm $(CNT_PREFIX)

testenv-shell:
	docker exec -it $(CNT_PREFIX)-nso$(NSO) bash -l

testenv-cli:
	docker exec -it $(CNT_PREFIX)-nso$(NSO) bash -lc 'ncs_cli -u admin'

testenv-runcmdC testenv-runcmdJ:
	@if [ -z "$(CMD)" ]; then echo "CMD variable must be set"; false; fi
	docker exec -t $(CNT_PREFIX)-nso$(NSO) bash -lc 'echo -e "$(CMD)" | ncs_cli -$(subst testenv-runcmd,,$@)u admin'

.PHONY: all build dev-shell push push-release tag-release test testenv-build testenv-clean-build testenv-start testenv-stop testenv-test
