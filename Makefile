ENV ?= dev
HELM_CHART := helm/task-tracker

.PHONY: k-render k-diff k-apply k-delete h-lint h-template h-install h-upgrade h-test h-uninstall

# ---------- Kustomize ----------
k-render:
	kubectl kustomize kustomize/overlays/$(ENV)

k-diff:
	kubectl diff -k kustomize/overlays/$(ENV)

k-apply:
	kubectl apply -k kustomize/overlays/$(ENV)

k-delete:
	kubectl delete -k kustomize/overlays/$(ENV)

# ---------- Helm (release name tt-<env>, namespace dso202-<env>) ----------
h-lint:
	helm lint $(HELM_CHART) -f helm/values-$(ENV).yaml

h-template:
	helm template tt-$(ENV) $(HELM_CHART) -f helm/values-$(ENV).yaml -n dso202-$(ENV)

h-install:
	helm upgrade --install tt-$(ENV) $(HELM_CHART) -f helm/values-$(ENV).yaml \
	  -n dso202-$(ENV) --create-namespace --rollback-on-failure --wait --timeout 5m

h-upgrade: h-install

h-test:
	helm test tt-$(ENV) -n dso202-$(ENV)

h-uninstall:
	helm uninstall tt-$(ENV) -n dso202-$(ENV)
