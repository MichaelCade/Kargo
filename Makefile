# --- Global Variables ---
ENV=dev
GITHUB_REPOSITORY_STRING := $(shell echo ${GITHUB_REPOSITORY} | tr '[:upper:]' '[:lower:]')
GITHUB_REPO_NAME := $(shell echo ${GITHUB_REPOSITORY_STRING} | awk -F '/' '{print $$2}')
GITHUB_REPO_ORG := $(shell echo ${GITHUB_REPOSITORY_STRING} | awk -F '/' '{print $$1}')
PULUMI_STACK := ${GITHUB_USER}/${GITHUB_REPO_NAME}/${ENV}

# --- Help ---
# Provides a detailed help message displaying all available commands
help:
	@echo "Available commands in the Kargo project Makefile:"
	@echo "  help             - Display this help message."
	@echo "  login            - Authenticate with Pulumi cloud services."
	@echo "  esc ENV=foobar   - Run Pulumi ESC environment. Default ENV='kubernetes'."
	@echo "  up               - Deploy Pulumi infrastructure using Pulumi stack."
	@echo "  down             - Destroy deployed Pulumi infrastructure."
	@echo "  talos-cluster    - Deploy a Talos Kubernetes cluster in Docker."
	@echo "  talos-config     - Generate and validate Talos configuration with patches."
	@echo "  talos            - Create and configure a Talos Kubernetes cluster."
	@echo "  kind             - Create a local Kubernetes cluster using Kind."
	@echo "  clean            - Clean up Pulumi resources and Kind/Talos clusters."
	@echo "  clean-all        - Perform 'clean' and remove Docker volumes."
	@echo "  act              - Test GitHub Actions locally."
	@echo "  konductor        - Update and sync .github/devcontainer submodule."
	@echo "  test             - Run setup tests (kind, up, clean, clean-all)."

# --- Pulumi Login Command ---
login:
	@echo "Logging in to Pulumi..."
	direnv allow
	PULUMI_ACCESS_TOKEN=${PULUMI_ACCESS_TOKEN} pulumi login
	pulumi install
	@echo "Login successful."

# --- Pulumi ESC ---
# Accepts one argument for Pulumi ESC environment; default is 'kubernetes'
# Usage:
#  - make esc ENV=dev
#  - make esc ENV=test
#  - make esc ENV=prod
esc: login
	$(eval ENV := $(or $(ENV),kubernetes))
	@echo "Running Pulumi ESC environment with argument ${ENV}..."
	@env esc open --format shell ${ENV}
	@echo "Pulumi ESC environment running."

# --- Pulumi Up ---
# Deploy Pulumi infrastructure
up: login
	@echo "Deploying Pulumi infrastructure..."
	pulumi stack select --create ${PULUMI_STACK}
	PULUMI_ACCESS_TOKEN=${PULUMI_ACCESS_TOKEN} pulumi up --yes --skip-preview --stack ${PULUMI_STACK}
	sleep 15
	kubectl get po -A
	@echo "Deployment complete."

# --- Pulumi Down ---
# Destroy Pulumi infrastructure
down: login
	@echo "Destroying Pulumi infrastructure..."
	PULUMI_ACCESS_TOKEN=${PULUMI_ACCESS_TOKEN} pulumi down --yes --skip-preview --stack ${PULUMI_STACK} || true
	@echo "Infrastructure teardown complete."

# --- Detect Architecture ---
# Function to detect the system architecture
detect-arch = $(shell uname -m | awk '{ if ($$1 == "x86_64") print "amd64"; else if ($$1 == "aarch64" || $$1 == "arm64") print "arm64"; else print "unknown" }')

# --- Create Talos Kubernetes Cluster ---
# Creates a Talos Kubernetes cluster in Docker with architecture detection and configuration patches
talos-cluster:
	@echo "Creating Talos Kubernetes Cluster..."
	@$(eval ARCH := $(detect-arch))
	@echo "Detected Architecture: $(ARCH)"
	@sudo talosctl cluster create --wait=false --arch=$(ARCH) --workers 1 --controlplanes 1 --provisioner docker --state=".talos/state" --exposed-ports="80:8080/tcp,443:8443/tcp,7445:7445/tcp" --config-patch '[{"op": "add", "path": "/cluster/proxy", "value": {"disabled": true}}, {"op":"add", "path": "/cluster/network/cni", "value": {"name": "none"}}]'
	@sudo talosctl config node 10.5.0.2
	@sudo talosctl kubeconfig --force --force-context-name kargo --merge=false ${KUBECONFIG}
	@sudo talosctl cluster show
	@sudo kubectl config get-contexts
	@sudo kubectl cluster-info

# --- Generate Talos Config with Patches ---
# Generates and validates Talos configuration with patches from the .talos/patch directory
talos-config:
	@echo "Generating Talos Config with Patches from .talos/patch directory..."
	@rm -rf .talos/{manifest,secret}/*
	@sudo talosctl gen secrets --force --output-file .talos/secret/secrets.yaml
	@sudo talosctl gen config kargo https://10.5.0.2:6443 --force --with-secrets .talos/secret/secrets.yaml --config-patch @.talos/patch/machine.yaml --kubernetes-version "1.29.0" --output .talos/manifest --with-examples=false --with-docs=false
	@sudo talosctl validate --mode container --config .talos/manifest/controlplane.yaml
	@sudo talosctl validate --mode container --config .talos/manifest/worker.yaml
	@echo "Talos Config Generated in .talos/manifest directory."

# --- Create and Configure Talos Cluster ---
# Wrapper target to generate Talos config and create the cluster
talos: login talos-config talos-cluster
	@echo "Talos Cluster Created."

# --- Wait for Kind Ready ---
# Waits for Kind cluster to be ready
kind-ready:
	@echo "Waiting for Kind Cluster to be ready..."
	kubectl wait --for=condition=Ready pod -l component=etcd --namespace=kube-system --timeout=180s
	kubectl wait --for=condition=Ready pod -l component=kube-apiserver --namespace=kube-system --timeout=180s
	kubectl wait --for=condition=Ready pod -l component=kube-controller-manager --namespace=kube-system --timeout=180s
	kubectl wait --for=condition=Ready pod -l component=kube-scheduler --namespace=kube-system --timeout=180s
	@echo "Kind Cluster is ready."

# --- Create Kind Cluster ---
# Creates a local Kubernetes cluster using Kind
kind-cluster:
	@echo "Creating Kind Cluster..."
	direnv allow
	mkdir -p ${HOME}/.kube .kube || true
	sudo docker volume create cilium-worker-n01
	sudo docker volume create cilium-worker-n02
	sudo docker volume create cilium-control-plane-n01
	sudo kind create cluster --config hack/kind.yaml
	sudo kind get kubeconfig --name cilium | tee .kube/config >/dev/null
	sudo kind get kubeconfig --name cilium | tee ${HOME}/.kube/config >/dev/null
	sleep 10
	kubectl get po -A
	@echo "Kind Cluster Created."

kind: login kind-cluster kind-ready

# --- Cleanup ---
clean: down
	@echo "Cleaning up..."
	sudo talosctl cluster destroy || true
	sudo talosctl config remove kargo --noconfirm || true
	sudo talosctl config remove kargo-1 --noconfirm || true
	sudo kind delete cluster --name cilium || true
	rm -rf .kube/config || true
	rm -rf .talos/config || true
	@echo "Cleanup complete."

clean-all: clean
	sudo docker volume rm cilium-worker-n01 || true
	sudo docker volume rm cilium-worker-n02 || true
	sudo docker volume rm cilium-control-plane-n01 || true
	@echo "Extended cleanup complete."

# --- GitHub Actions ---
act: clean
	@echo "Testing GitHub Workflows locally."
	PULUMI_ACCESS_TOKEN=${PULUMI_ACCESS_TOKEN} sudo --preserve-env act --rm --container-options "--privileged" --verbose --var PULUMI_ACCESS_TOKEN="${PULUMI_ACCESS_TOKEN}" --var GITHUB_TOKEN="${GITHUB_TOKEN}" --var ACTIONS_RUNTIME_TOKEN="${GITHUB_TOKEN}" --var GHA_GITHUB_TOKEN="${GITHUB_TOKEN}"
	@echo "GitHub Workflow Test Complete."

# --- Maintain Devcontainer ---
konductor:
	git submodule update --init --recursive .github/konductor
	git submodule update --remote --merge .github/konductor
	rsync -av .github/konductor/.devcontainer/* .devcontainer
	docker pull ghcr.io/containercraft/konductor:latest

stop:
	@echo "Stopping Github Codespace"
	gh codespace stop --codespace ${CODESPACE_NAME}

# --- Testing ---
test: kind up clean clean-all

# --- Default Command ---
all: help
