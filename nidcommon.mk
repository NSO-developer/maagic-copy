# The NSO in Docker ecosystem provides for parameterized execution of build and
# test environments for NSO package projects across multiple NSO versions.
#
# Running a test of a package means that we spin up one or more test containers
# based on a given state (commit) of a repository. They are part of one (CI)
# pipeline, though note that it can be run locally. We reuse the CI nomenclature
# even for local runs as it makes things easier to understand. The test
# environment (testenv) can consist of multiple containers, for example one
# netsim container and one NSO container.
#
# The version of NSO build and test with is always a parameter as it is crucial
# that packages can be built for different versions of NSO and it is good
# hygiene to continuously ensure that it works correctly with multiple versions
# of NSO (typically the tip of each release train). Each NSO version results in
# one CI job within a CI pipeline.
#
# For each CI job, there can be multiple containers. For example, one NSO
# container and one netsim container.
#
# The conceptual structure looks like this:
#
# - pipeline (per change / commit pushed / test started)
#   - job (per NSO version)
#     - multiple containers, as needed
#
# And here is what it might look like in reality. The commits FOO and BAR lead
# to starting CI pipelines to test the changes. Each CI pipeline runs two CI
# jobs, one for version 4.7.6 of NSO and one for NSO 5.3. In each CI job there
# are two containers, one for NSO itself and one for a netsim.
#
# - pipeline: commit FOO
#   - job: NSO 4.7.6
#     - NSO container
#     - netsim X container
#   - job: NSO 5.3
#     - NSO container
#     - netsim X container
# - pipeline: commit BAR
#   - job: NSO 4.7.6
#     - NSO container
#     - netsim X container
#   - job: NSO 5.3
#     - NSO container
#     - netsim X container
#
# - PNS is the pipeline or pseudo-namespace which is per CI pipeline. In a CI
#   environment it allows concurrent execution of multiple pipelines (to evalute
#   multiple changes) without collisions. When run locally it is based on your
#   username and thus you can conceptually not run testenvs for multiple commits
#   at the same time, however as git only allows checking out one version of a
#   time this is typically not an issue. Containers should have a label based on
#   PNS which allows the clean up of all containers through one single filter
#   and action.
# - CNT_PREFIX is per CI job and is what allows multiple jobs to be run in
#   parallel for different versions of NSO. When run locally, it is based on
#   your username as well as the NSO version, still making it possible to start
#   multiple testenvs for your code based on different NSO versions.
# - DOCKER_TAG must be unique per CI job and so is based on CI_JOB_ID when run
#   in CI (but also includes NSO version to make it easier to visually inspect)
#   or your username and NSO version when run locally.
# - OLD_DOCKER_TAG is just like DOCKER_TAG but allows a second NSO version to be
#   specified which is required for multi version tests (a.k.a upgrade tests)
#
# These Makefiles could be simplified, for example by removing the NSO version,
# but as it's considered good hygiene to test across multiple NSO versions, the
# recommendation is to get across the threshold and use them in the prescribed
# manner.

# helper function to turn a string into lower case
lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$1))))))))))))))))))))))))))

# require that NSO_VERSION is set
ifeq ($(NSO_VERSION),)
$(error "ERROR: variable NSO_VERSION must be set, for example to '5.2.1' to build based on NSO version 5.2.1")
endif
NSO_VERSION_MAJOR=$(shell echo ${NSO_VERSION} | sed 's/^\([0-9]\+\)\..*/\1/')
NSO_VERSION_MINOR=$(shell echo ${NSO_VERSION} | sed 's/^[0-9]\+\.\([0-9]\+\).*/\1/')

# Set PNS - our pseudo-namespace or pipeline namespace. All containers running
# within a CI pipeline will have the same namespace, which isn't a namespace
# like what Linux supports but it's just a prefix used for the docker containers
# to guarantee uniqueness.
ifneq ($(CI_PIPELINE_ID),)
PNS:=$(CI_PIPELINE_ID)
else
ifneq ($(NSO_VERSION),)
PNS:=$(shell whoami | sed 's/[^[:alnum:]._-]\+/_/g')
endif
endif

# set the docker tag to use, if not already set
DOCKER_TAG?=$(NSO_VERSION)-$(PNS)
CNT_PREFIX?=testenv-$(PROJECT_NAME)-$(NSO_VERSION)-$(PNS)

# There are three important paths that we provide:
# - NSO_IMAGE_PATH is the path to where we can find the standard nso-docker images
#   cisco-nso-base and cisco-nso-dev
# - IMAGE_PATH is the path to where we should write our resulting output images
# - PKG_PATH is the path from where we pull in dependencies, i.e. the included
#   packages
# All three are derived from information we get from GitLab CI, if available.
# These defaults can be overridden simply by setting the variables in the
# environment. Makefile variable macros are available from within the Makefile,
# we export them to also make them available to subshells.
ifneq ($(CI_REGISTRY),)
export NSO_IMAGE_PATH?=$(call lc,$(CI_REGISTRY)/$(CI_PROJECT_NAMESPACE)/nso-docker/)
export IMAGE_PATH?=$(call lc,$(CI_REGISTRY)/$(CI_PROJECT_NAMESPACE)/)
export PKG_PATH?=$(call lc,$(CI_REGISTRY)/$(CI_PROJECT_NAMESPACE)/)
endif

DOCKER_ARGS=--network $(CNT_PREFIX) --label $(CNT_PREFIX)
DOCKER_NSO_ARGS=$(DOCKER_ARGS) --label nidtype=nso --volume /var/opt/ncs/packages

# Determine which xargs we have. BSD xargs does not have --no-run-if-empty,
# rather, it is the default behavior so the argument is simply superfluous. We
# check if we are using GNU xargs by trying to run xargs --version and grep for
# 'GNU', if that returns 0 we are on GNU and will use 'xargs --no-run-if-empty',
# otherwise we are on BSD and will use 'xargs' straight up.
XARGS_CHECK := $(shell xargs --version 2>&1 | grep GNU >/dev/null 2>&1; echo $$?)
ifeq ($(XARGS_CHECK),0)
	XARGS := xargs --no-run-if-empty
else
	XARGS := xargs
endif

.PHONY: check-nid-available

check-nid-available:
# Check for the existance of the NID base and dev images.
# We don't need this check from a strictly functional perspective as builds or
# tests would fail anyway but by explicitly checking we can make some
# guesstimates and provide hints to the user on what might be wrong.
	@echo "Checking NSO in Docker images are available..." \
		&& docker inspect $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION) >/dev/null 2>&1 \
		|| (echo "ERROR: The docker image $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION) does not exist"; \
			if [ -z "$(NSO_IMAGE_PATH)" ]; then \
				docker image inspect $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION)-$(PNS) >/dev/null 2>&1 \
					&& echo "HINT: You have a locally built image cisco-nso-base:$(NSO_VERSION)-$(PNS), use it for this build by setting NSO_VERSION=$(NSO_VERSION)-$(PNS) or retag it by using the 'tag-release' make target in the nso-docker repo where the image was built" && exit 1; \
				docker image inspect $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION)-$(PNS) >/dev/null 2>&1 \
					|| echo "HINT: Set NSO_IMAGE_PATH to the registry path of the nso-docker repo, for example 'registry.gitlab.com/nso-developer/nso-docker/'" && false; \
			else \
				echo "Image not found locally, pulling from registry..."; \
				docker pull $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION) 2>/dev/null \
					|| (echo "ERROR: $(NSO_IMAGE_PATH)cisco-nso-base:$(NSO_VERSION) not found"; \
							echo "$(NSO_IMAGE_PATH)" | grep "/$$" >/dev/null || echo "HINT: did you forget a trailing '/' in NSO_IMAGE_PATH?"; \
							echo "HINT: Is NSO_IMAGE_PATH correctly set? Set NSO_IMAGE_PATH to the registry URL of the nso-docker repo, for example 'registry.gitlab.com/nso-developer/nso-docker/'"; \
							false); \
			fi)
