# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# 	http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ROOT_DIR_RELATIVE := .

include $(ROOT_DIR_RELATIVE)/common.mk

# If you update this file, please follow
# https://suva.sh/posts/well-documented-makefiles

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on
unexport GOPATH

# Directories.
ARTIFACTS ?= $(REPO_ROOT)/_artifacts
TOOLS_DIR := hack/tools
TOOLS_DIR_DEPS := $(TOOLS_DIR)/go.sum $(TOOLS_DIR)/go.mod $(TOOLS_DIR)/Makefile
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin

BIN_DIR := bin
REPO_ROOT := $(shell git rev-parse --show-toplevel)
GH_REPO ?= kubernetes-sigs/cluster-api-provider-openstack
TEST_E2E_DIR := test/e2e

# Files
E2E_DATA_DIR ?= $(REPO_ROOT)/test/e2e/data
E2E_CONF_PATH  ?= $(E2E_DATA_DIR)/e2e_conf.yaml
KUBETEST_CONF_PATH ?= $(abspath $(E2E_DATA_DIR)/kubetest/conformance.yaml)
KUBETEST_FAST_CONF_PATH ?= $(abspath $(E2E_DATA_DIR)/kubetest/conformance-fast.yaml)
GO_INSTALL := ./scripts/go_install.sh

# Binaries.
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/controller-gen
CONVERSION_GEN := $(TOOLS_BIN_DIR)/conversion-gen
DEFAULTER_GEN := $(TOOLS_BIN_DIR)/defaulter-gen
ENVSUBST := $(TOOLS_BIN_DIR)/envsubst
GINKGO := $(TOOLS_BIN_DIR)/ginkgo
GOJQ := $(TOOLS_BIN_DIR)/gojq
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
KUSTOMIZE := $(TOOLS_BIN_DIR)/kustomize
MOCKGEN := $(TOOLS_BIN_DIR)/mockgen
RELEASE_NOTES := $(TOOLS_BIN_DIR)/release-notes

# Setup-envtest
SETUP_ENVTEST_VER := v0.0.0-20211110210527-619e6b92dab9
SETUP_ENVTEST_BIN := setup-envtest
SETUP_ENVTEST := $(abspath $(TOOLS_BIN_DIR)/$(SETUP_ENVTEST_BIN)-$(SETUP_ENVTEST_VER))
SETUP_ENVTEST_PKG := sigs.k8s.io/controller-runtime/tools/setup-envtest

# Kubebuilder
export KUBEBUILDER_ENVTEST_KUBERNETES_VERSION ?= 1.23.3
export KUBEBUILDER_CONTROLPLANE_START_TIMEOUT ?= 60s
export KUBEBUILDER_CONTROLPLANE_STOP_TIMEOUT ?= 60s

PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)
export PATH
export DOCKER_CLI_EXPERIMENTAL=enabled
export DOCKER_BUILDKIT=1

PODMAN ?= 0
ifeq ($(PODMAN), 1)
	CONTAINERFILE ?= Containerfile
else
	CONTAINERFILE ?= Dockerfile
endif

# Release variables

STAGING_REGISTRY := gcr.io/k8s-staging-capi-openstack
STAGING_BUCKET ?= artifacts.k8s-staging-capi-openstack.appspot.com
BUCKET ?= $(STAGING_BUCKET)
PROD_REGISTRY ?= k8s.gcr.io/capi-openstack
REGISTRY ?= $(STAGING_REGISTRY)
RELEASE_TAG ?= $(shell git describe --abbrev=0 2>/dev/null)
PULL_BASE_REF ?= $(RELEASE_TAG) # PULL_BASE_REF will be provided by Prow
RELEASE_ALIAS_TAG ?= $(PULL_BASE_REF)
RELEASE_DIR := out

TAG ?= dev
ARCH ?= amd64
ALL_ARCH ?= amd64 arm arm64 ppc64le s390x

# main controller
IMAGE_NAME ?= capi-openstack-controller
CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)
CONTROLLER_IMG_TAG ?= $(CONTROLLER_IMG)-$(ARCH):$(TAG)
CONTROLLER_ORIGINAL_IMG := gcr.io/k8s-staging-capi-openstack/capi-openstack-controller
CONTROLLER_NAME := capo-controller-manager
MANIFEST_FILE := infrastructure-components
CONFIG_DIR := config
NAMESPACE := capo-system

# Allow overriding manifest generation destination directory
MANIFEST_ROOT ?= config
CRD_ROOT ?= $(MANIFEST_ROOT)/crd/bases
WEBHOOK_ROOT ?= $(MANIFEST_ROOT)/webhook
RBAC_ROOT ?= $(MANIFEST_ROOT)/rbac

# Allow overriding the imagePullPolicy
PULL_POLICY ?= Always

# Set build time variables including version details
LDFLAGS := $(shell source ./hack/version.sh; version::ldflags)


## --------------------------------------
## Testing
## --------------------------------------

# The number of ginkgo tests to run concurrently
E2E_GINKGO_PARALLEL=2

E2E_ARGS ?=

$(ARTIFACTS):
	mkdir -p $@

ifeq ($(shell go env GOOS),darwin) # Use the darwin/amd64 binary until an arm64 version is available
  KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path --arch amd64 $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))
else
  KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))
endif

.PHONY: test
test: $(SETUP_ENVTEST) ## Run tests
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" go test -v ./... $(TEST_ARGS)

E2E_TEMPLATES_DIR=test/e2e/data/infrastructure-openstack
E2E_KUSTOMIZE_DIR=test/e2e/data/kustomize

.PHONY: e2e-templates
e2e-templates: ## Generate cluster templates for e2e tests
e2e-templates: $(addprefix $(E2E_TEMPLATES_DIR)/, \
		 cluster-template-external-cloud-provider.yaml \
		 cluster-template-multi-az.yaml \
		 cluster-template-multi-network.yaml \
		 cluster-template-without-lb.yaml \
		 cluster-template.yaml)

$(E2E_TEMPLATES_DIR)/cluster-template.yaml: $(E2E_KUSTOMIZE_DIR)/with-tags $(KUSTOMIZE) FORCE
	$(KUSTOMIZE) build "$<" > "$@"

$(E2E_TEMPLATES_DIR)/cluster-template-%.yaml: $(E2E_KUSTOMIZE_DIR)/% $(KUSTOMIZE) FORCE
	$(KUSTOMIZE) build "$<" > "$@"

e2e-prerequisites: $(GINKGO) e2e-templates e2e-image test-e2e-image-prerequisites ## Build all artifacts required by e2e tests

# Can be run manually, e.g. via:
# export OPENSTACK_CLOUD_YAML_FILE="$(pwd)/clouds.yaml"
# E2E_GINKGO_ARGS="-stream -focus='default'" E2E_ARGS="-use-existing-cluster='true'" make test-e2e
E2E_GINKGO_ARGS ?=
.PHONY: test-e2e ## Run e2e tests using clusterctl
test-e2e: e2e-prerequisites ## Run e2e tests
	time $(GINKGO) --failFast -trace -progress -v -tags=e2e --nodes=$(E2E_GINKGO_PARALLEL) $(E2E_GINKGO_ARGS) ./test/e2e/suites/e2e/... -- -config-path="$(E2E_CONF_PATH)" -artifacts-folder="$(ARTIFACTS)" --data-folder="$(E2E_DATA_DIR)" $(E2E_ARGS)

.PHONY: e2e-image
e2e-image: CONTROLLER_IMG_TAG = "gcr.io/k8s-staging-capi-openstack/capi-openstack-controller:e2e"
e2e-image: docker-build

# Pull all the images references in test/e2e/data/e2e_conf.yaml
test-e2e-image-prerequisites:
	docker pull gcr.io/k8s-staging-cluster-api/cluster-api-controller:v1.2.0
	docker pull gcr.io/k8s-staging-cluster-api/kubeadm-bootstrap-controller:v1.2.0
	docker pull gcr.io/k8s-staging-cluster-api/kubeadm-control-plane-controller:v1.2.0
	docker pull quay.io/jetstack/cert-manager-cainjector:v1.8.2
	docker pull quay.io/jetstack/cert-manager-webhook:v1.8.2
	docker pull quay.io/jetstack/cert-manager-controller:v1.8.2

CONFORMANCE_E2E_ARGS ?= -kubetest.config-file=$(KUBETEST_CONF_PATH)
CONFORMANCE_E2E_ARGS += $(E2E_ARGS)
CONFORMANCE_GINKGO_ARGS ?= -stream
.PHONY: test-conformance
test-conformance: e2e-prerequisites ## Run clusterctl based conformance test on workload cluster (requires Docker).
	time $(GINKGO) -trace -progress -v -tags=e2e -focus="conformance" $(CONFORMANCE_GINKGO_ARGS) ./test/e2e/suites/conformance/... -- -config-path="$(E2E_CONF_PATH)" -artifacts-folder="$(ARTIFACTS)" --data-folder="$(E2E_DATA_DIR)" $(CONFORMANCE_E2E_ARGS)

test-conformance-fast: ## Run clusterctl based conformance test on workload cluster (requires Docker) using a subset of the conformance suite in parallel.
	$(MAKE) test-conformance CONFORMANCE_E2E_ARGS="-kubetest.config-file=$(KUBETEST_FAST_CONF_PATH) -kubetest.ginkgo-nodes=5 $(E2E_ARGS)"


## --------------------------------------
## Binaries
## --------------------------------------

.PHONY: binaries
binaries: managers ## Builds and installs all binaries

.PHONY: managers
managers:
	$(MAKE) manager-openstack-infrastructure

.PHONY: manager-openstack-infrastructure
manager-openstack-infrastructure: ## Build manager binary.
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "${LDFLAGS} -extldflags '-static'" -o $(BIN_DIR)/manager .

$(SETUP_ENVTEST): # Build setup-envtest from tools folder.
	GOBIN=$(abspath $(TOOLS_BIN_DIR)) $(GO_INSTALL) $(SETUP_ENVTEST_PKG) $(SETUP_ENVTEST_BIN) $(SETUP_ENVTEST_VER)

.PHONY: $(SETUP_ENVTEST_BIN)
	$(SETUP_ENVTEST_BIN): $(SETUP_ENVTEST) ## Build a local copy of setup-envtest.

## --------------------------------------
## Linting
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT) ## Lint codebase
	$(GOLANGCI_LINT) run -v --fast=false

.PHONY: lint-update
lint-update: $(GOLANGCI_LINT) ## Lint codebase
	$(GOLANGCI_LINT) run -v --fast=false --fix

lint-fast: $(GOLANGCI_LINT) ## Run only faster linters to detect possible issues
	$(GOLANGCI_LINT) run -v --fast=true

## --------------------------------------
## Generate
## --------------------------------------

.PHONY: modules
modules: ## Runs go mod to ensure proper vendoring.
	go mod tidy
	cd $(TOOLS_DIR); go mod tidy

.PHONY: generate
generate: ## Generate code
	$(MAKE) generate-go
	$(MAKE) generate-manifests

.PHONY: generate-go
generate-go: $(MOCKGEN)
	$(MAKE) -B $(CONTROLLER_GEN) $(CONVERSION_GEN) $(DEFAULTER_GEN)
	$(CONTROLLER_GEN) \
		paths=./api/... \
		object:headerFile=./hack/boilerplate/boilerplate.generatego.txt
	$(CONVERSION_GEN) \
		--input-dirs=./api/v1alpha3 \
		--input-dirs=./api/v1alpha4 \
		--input-dirs=./api/v1alpha5 \
		--input-dirs=./api/v1alpha6 \
		--output-file-base=zz_generated.conversion \
		--go-header-file=./hack/boilerplate/boilerplate.generatego.txt
	go generate ./...

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) \
		paths=./api/... \
		crd:crdVersions=v1 \
		output:crd:dir=$(CRD_ROOT) \
		output:webhook:dir=$(WEBHOOK_ROOT) \
		webhook
	$(CONTROLLER_GEN) \
		paths=./controllers/... \
		output:rbac:dir=$(RBAC_ROOT) \
		rbac:roleName=manager-role

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-build
docker-build: docker-pull-prerequisites ## Build the docker image for controller-manager
	docker build -f $(CONTAINERFILE) --build-arg goproxy=$(GOPROXY) --build-arg ARCH=$(ARCH) --build-arg LDFLAGS="$(LDFLAGS)" . -t $(CONTROLLER_IMG_TAG)

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CONTROLLER_IMG_TAG)

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	[ "$(PODMAN)" -eq 0 ] && docker pull docker.io/docker/dockerfile:1.1-experimental
	docker pull docker.io/library/golang:$(GOLANG_VERSION)
	docker pull gcr.io/distroless/static:latest

## --------------------------------------
## Docker — All ARCH
## --------------------------------------

.PHONY: docker-build-all ## Build all the architecture docker images
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-manifest

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-manifest
docker-push-manifest: ## Push the fat manifest docker image.
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge ${CONTROLLER_IMG}:${TAG}

.PHONY: staging-manifests
staging-manifests:
	$(MAKE) $(RELEASE_DIR)/$(MANIFEST_FILE).yaml PULL_POLICY=IfNotPresent TAG=$(RELEASE_ALIAS_TAG)

## --------------------------------------
## Release
## --------------------------------------

$(RELEASE_DIR):
	mkdir -p $@

.PHONY: list-staging-releases
list-staging-releases: ## List staging images for image promotion
	@echo $(IMAGE_NAME):
	$(MAKE) list-image RELEASE_TAG=$(RELEASE_TAG) IMAGE=$(IMAGE_NAME)

list-image:
	gcloud container images list-tags $(STAGING_REGISTRY)/$(IMAGE) --filter="tags=('$(RELEASE_TAG)')" --format=json

.PHONY: release
release: $(RELEASE_NOTES) clean-release $(RELEASE_DIR)  ## Builds and push container images using the latest git tag for the commit.
	@if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	@if ! [ -z "$$(git status --porcelain)" ]; then echo "Your local git repository contains uncommitted changes, use git clean before proceeding."; fi
	git checkout "${RELEASE_TAG}"
	# Set the manifest image to the production bucket.
	$(MAKE) manifest-modification REGISTRY=$(PROD_REGISTRY)
	$(MAKE) release-manifests
	$(MAKE) release-templates

.PHONY: manifest-modification
manifest-modification: # Set the manifest images to the staging/production bucket.
	$(MAKE) set-manifest-image \
		MANIFEST_IMG=$(REGISTRY)/$(IMAGE_NAME) MANIFEST_TAG=$(RELEASE_TAG) \
		TARGET_RESOURCE="./config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy PULL_POLICY=IfNotPresent TARGET_RESOURCE="./config/default/manager_pull_policy.yaml"

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' $(TARGET_RESOURCE)

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resources)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' $(TARGET_RESOURCE)

.PHONY: release-manifests
release-manifests:
	$(MAKE) $(RELEASE_DIR)/$(MANIFEST_FILE).yaml TAG=$(RELEASE_TAG) PULL_POLICY=IfNotPresent
	# Add metadata to the release artifacts
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml

.PHONY: release-staging
release-staging: ## Builds and push container images and manifests to the staging bucket.
	$(MAKE) docker-build-all
	$(MAKE) docker-push-all
	$(MAKE) release-alias-tag
	$(MAKE) staging-manifests
	$(MAKE) upload-staging-artifacts

.PHONY: release-staging-nightly
release-staging-nightly: ## Tags and push container images to the staging bucket. Example image tag: capi-openstack-controller:nightly_master_20210121
	$(eval NEW_RELEASE_ALIAS_TAG := nightly_$(RELEASE_ALIAS_TAG)_$(shell date +'%Y%m%d'))
	echo $(NEW_RELEASE_ALIAS_TAG)
	$(MAKE) release-alias-tag TAG=$(RELEASE_ALIAS_TAG) RELEASE_ALIAS_TAG=$(NEW_RELEASE_ALIAS_TAG)
	$(MAKE) staging-manifests RELEASE_ALIAS_TAG=$(NEW_RELEASE_ALIAS_TAG)
	$(MAKE) upload-staging-artifacts RELEASE_ALIAS_TAG=$(NEW_RELEASE_ALIAS_TAG)

.PHONY: upload-staging-artifacts
upload-staging-artifacts: ## Upload release artifacts to the staging bucket
	gsutil cp $(RELEASE_DIR)/* gs://$(STAGING_BUCKET)/components/$(RELEASE_ALIAS_TAG)/

.PHONY: create-gh-release
create-gh-release:$(GH) ## Create release on Github
	$(GH) release create $(VERSION) -d -F $(RELEASE_DIR)/CHANGELOG.md -t $(VERSION) -R $(GH_REPO)

.PHONY: upload-gh-artifacts
upload-gh-artifacts: $(GH) ## Upload artifacts to Github release
	$(GH) release upload $(VERSION) -R $(GH_REPO) --clobber  $(RELEASE_DIR)/*

.PHONY: release-alias-tag
release-alias-tag: # Adds the tag to the last build tag.
	gcloud container images add-tag -q $(CONTROLLER_IMG):$(TAG) $(CONTROLLER_IMG):$(RELEASE_ALIAS_TAG)

.PHONY: release-notes
release-notes: $(RELEASE_NOTES) ## Generate release notes
	$(RELEASE_NOTES) $(RELEASE_NOTES_ARGS)

.PHONY: templates
templates: ## Generate cluster templates
templates: templates/cluster-template.yaml \
	   templates/cluster-template-without-lb.yaml \
	   templates/cluster-template-external-cloud-provider.yaml

templates/cluster-template.yaml: kustomize/v1alpha6/default $(KUSTOMIZE) FORCE
	$(KUSTOMIZE) build "$<" > "$@"

templates/cluster-template-%.yaml: kustomize/v1alpha6/% $(KUSTOMIZE) FORCE
	$(KUSTOMIZE) build "$<" > "$@"

.PHONY: release-templates
release-templates: $(RELEASE_DIR) templates ## Generate release templates
	cp templates/cluster-template*.yaml $(RELEASE_DIR)/

IMAGE_PATCH_DIR := $(ARTIFACTS)/image-patch

$(IMAGE_PATCH_DIR): $(ARTIFACTS)
	mkdir -p $@

.PHONY: $(RELEASE_DIR)/$(MANIFEST_FILE).yaml
$(RELEASE_DIR)/$(MANIFEST_FILE).yaml:
	$(MAKE) compiled-manifest \
		PROVIDER=$(MANIFEST_FILE) \
		OLD_IMG=$(CONTROLLER_ORIGINAL_IMG) \
		MANIFEST_IMG=$(CONTROLLER_IMG) \
		CONTROLLER_NAME=$(CONTROLLER_NAME) \
		PROVIDER_CONFIG_DIR=$(CONFIG_DIR) \
		NAMESPACE=$(NAMESPACE)

.PHONY: compiled-manifest
compiled-manifest: $(RELEASE_DIR) $(KUSTOMIZE)
	$(MAKE) image-patch-source-manifest
	$(MAKE) image-patch-pull-policy
	$(MAKE) image-patch-kustomization
	$(KUSTOMIZE) build $(IMAGE_PATCH_DIR)/$(PROVIDER) > $(RELEASE_DIR)/$(PROVIDER).yaml

.PHONY: image-patch-source-manifest
image-patch-source-manifest: $(IMAGE_PATCH_DIR) $(KUSTOMIZE)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	$(KUSTOMIZE) build $(PROVIDER_CONFIG_DIR)/default > $(IMAGE_PATCH_DIR)/$(PROVIDER)/source-manifest.yaml

.PHONY: image-patch-kustomization
image-patch-kustomization: $(IMAGE_PATCH_DIR)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	$(GOJQ) --yaml-input --yaml-output '.images[0]={"name":"$(OLD_IMG)","newName":"$(MANIFEST_IMG)","newTag":"$(TAG)"}|del(.patchesJson6902[1])|.patchesJson6902[0].target.name="$(CONTROLLER_NAME)"|.patchesJson6902[0].target.namespace="$(NAMESPACE)"' \
		"hack/image-patch/kustomization.yaml" > $(IMAGE_PATCH_DIR)/$(PROVIDER)/kustomization.yaml

.PHONY: image-patch-pull-policy
image-patch-pull-policy: $(IMAGE_PATCH_DIR) $(GOJQ)
	mkdir -p $(IMAGE_PATCH_DIR)/$(PROVIDER)
	echo Setting imagePullPolicy to $(PULL_POLICY)
	$(GOJQ) --yaml-input --yaml-output '.[0].value="$(PULL_POLICY)"' "hack/image-patch/pull-policy-patch.yaml" > $(IMAGE_PATCH_DIR)/$(PROVIDER)/pull-policy-patch.yaml


## --------------------------------------
## Cleanup / Verification
## --------------------------------------

.PHONY: clean
clean: ## Remove all generated files
	$(MAKE) -C hack/tools clean
	$(MAKE) clean-bin
	$(MAKE) clean-temporary

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf bin

.PHONY: clean-temporary
clean-temporary: ## Remove all temporary files and folders
	rm -f minikube.kubeconfig
	rm -f kubeconfig
	rm -rf _artifacts

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

.PHONY: verify
verify: verify-boilerplate verify-modules verify-gen

.PHONY: verify-boilerplate
verify-boilerplate:
	./hack/verify-boilerplate.sh

.PHONY: verify-modules
verify-modules: modules
	@if !(git diff --quiet HEAD -- go.sum go.mod hack/tools/go.mod hack/tools/go.sum); then \
		git diff; \
		echo "go module files are out of date"; exit 1; \
	fi

verify-gen: generate
	@if !(git diff --quiet HEAD); then \
		git diff; \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi

.PHONY: compile-e2e
compile-e2e: ## Test e2e compilation
	go test -c -o /dev/null -tags=e2e ./test/e2e/suites/conformance

.PHONY: FORCE
FORCE:
