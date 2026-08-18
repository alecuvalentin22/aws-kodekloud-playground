# Platform lab -- entry point.
#
# Everything here shells out to scripts/ and ansible; this is Make used as a
# task runner, not a build system (nothing produces files). `just` or Taskfile
# are more honest about that distinction -- Make is here because it is on every
# machine and every reviewer recognises it.
#
#   make help          what you can do
#   make gitops        the full GitOps lab, from nothing
#   make scenarios     list the experiments

SHELL := /bin/bash
.DEFAULT_GOAL := help

KUBECONFIG ?= $(HOME)/.kube/eks-real
export KUBECONFIG

TF_AWS  := terraform/aws
TF_EKS  := terraform/eks
VAULT   ?= --ask-vault-pass
KEY     ?= ~/.ssh/id_ed25519

.PHONY: help
help: ## show this help
	@echo "Platform lab"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-18s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "  KUBECONFIG=$(KUBECONFIG)"

# --- credentials & state ----------------------------------------------------
.PHONY: whoami
whoami: ## show which AWS account and cluster you are pointed at
	@aws sts get-caller-identity --query '{account:Account,arn:Arn}' --output table 2>/dev/null \
	  || echo "  no AWS credentials in this shell"
	@kubectl config current-context 2>/dev/null | sed 's/^/  kube context: /' || true

.PHONY: state
state: ## create the S3 state bucket and init backends
	./scripts/tf-init.sh

# --- infrastructure ---------------------------------------------------------
.PHONY: eks
eks: ## build the EKS cluster with self-managed nodes
	cd $(TF_EKS) && terraform apply -auto-approve
	@$(MAKE) --no-print-directory kubeconfig

.PHONY: kubeconfig
kubeconfig: ## write a DEDICATED kubeconfig (never touches ~/.kube/config)
	aws eks update-kubeconfig --region us-east-1 --name andrei-lab-eks --alias eks-real
	@kubectl get nodes

.PHONY: ec2
ec2: ## build the EC2 lab (Elasticsearch, k3s, RKE2)
	cd $(TF_AWS) && terraform apply -auto-approve

# --- gitops -----------------------------------------------------------------
.PHONY: gitops
gitops: argocd flux bootstrap ## install both controllers and bootstrap from git

.PHONY: argocd
argocd: ## install Argo CD
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts \
	  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=600s

.PHONY: flux
flux: ## install Flux controllers
	flux install --namespace=flux-system \
	  --components=source-controller,kustomize-controller,helm-controller,notification-controller

.PHONY: bootstrap
bootstrap: ## point both controllers at this repo
	kubectl apply -f gitops/argocd/bootstrap/root-app.yaml
	kubectl apply -f gitops/flux/clusters/eks/

.PHONY: status
status: ## what both controllers currently think
	@./scripts/scenario status

.PHONY: ui
ui: ## port-forward the Argo CD UI (admin password printed)
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d | sed 's/^/  password: /'; echo
	@echo "  https://localhost:8080"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

.PHONY: urls
urls: ## where the demo apps are reachable
	@./scripts/app-urls.sh

# --- experiments ------------------------------------------------------------
.PHONY: scenarios
scenarios: ## list the GitOps experiments
	@./scripts/scenario list

.PHONY: scenario
scenario: ## run one, e.g. make scenario ID=03
	@./scripts/scenario run $(ID)

# --- teardown ---------------------------------------------------------------
.PHONY: destroy
destroy: ## destroy everything (asks first)
	@read -p "Destroy all lab infrastructure? [y/N] " a; [ "$$a" = "y" ] || exit 1
	-cd $(TF_EKS) && terraform destroy -auto-approve
	-cd $(TF_AWS) && terraform destroy -auto-approve
