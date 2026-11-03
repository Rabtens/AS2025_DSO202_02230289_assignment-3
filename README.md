# DSO202 - Assignment 3: Unit IV Package & Configuration Management (Kustomize + Helm)

 **Builds on:** [Assignment 2](https://github.com/Rabtens/AS2025_DSO202_02230289_assignment-2)

Assignment 2 deployed the Task Tracker to **one** namespace from flat YAML files, with values such as the namespace, host name, replica counts and passwords written straight into the manifests. To run the same application in dev, staging and prod, those files would have to be copied three times, and every later change would have to be made three times. This assignment removes that duplication twice, with the two tools from the Unit IV lectures:

| Tool | Method | Where | One-line idea |
|---|---|---|---|
| **Kustomize** | patches plain YAML: base + overlays | [`kustomize/`](kustomize) | *Base stores what is shared. Overlay stores what is different. Kustomize renders the final YAML.* |
| **Helm** | renders templates with values, tracks releases | [`helm/`](helm) | One chart, one values file per environment, every change recorded as a revision. |

| Environment | Namespace | Host | Backend / frontend replicas | Istio mesh |
|---|---|---|---|---|
| dev | `dso202-dev` | `dev.tasktracker.local` | 1 / 1 | no |
| staging | `dso202-staging` | `staging.tasktracker.local` | 2 / 2 | no |
| prod | `dso202-prod` | `tasktracker.local` | 3 / 3 (bigger backend limits) | yes (STRICT mTLS + deny-all) |

The database stays a 1-replica StatefulSet in every environment, for the reason given in Assignment 2 (the stock Postgres image does not replicate).

---

## 1. Repository layout

```
assignment-3/
├── README.md
├── Makefile                          # make k-render ENV=dev | make h-install ENV=prod ...
├── Evidences/                        # screenshots
├── kustomize/
│   ├── base/                         # shared by every environment
│   │   ├── kustomization.yaml        #   resources + configMapGenerator + secretGenerator
│   │   ├── config.env  secret.env    #   generator inputs
│   │   ├── rbac.yaml  database.yaml  backend.yaml  frontend.yaml  ingress.yaml
│   ├── istio/                        # optional mesh policy (only prod includes it)
│   │   ├── kustomization.yaml
│   │   └── istio.yaml
│   └── overlays/
│       ├── dev/      kustomization.yaml  namespace.yaml  patch-ingress-host.yaml
│       ├── staging/  kustomization.yaml  namespace.yaml  patch-ingress-host.yaml
│       └── prod/     kustomization.yaml  namespace.yaml  patch-resources.yaml  patch-ingress-mesh.yaml
└── helm/
    ├── task-tracker/                 # the chart
    │   ├── Chart.yaml  values.yaml  values.schema.json  .helmignore
    │   └── templates/
    │       ├── _helpers.tpl  configmap.yaml  secret.yaml  database.yaml
    │       ├── backend.yaml  frontend.yaml  ingress.yaml  rbac.yaml  istio.yaml
    │       ├── NOTES.txt
    │       └── tests/test-connection.yaml
    ├── values-dev.yaml
    ├── values-staging.yaml
    └── values-prod.yaml
```
![alt text](<Evidences/Screenshot from 2026-11-03 18-25-23.png>)

---

## 2. Prerequisites

| Requirement | Check |
|---|---|
| kind cluster `dso202` (from Assignments 1 and 2) | `kubectl cluster-info --context kind-dso202` |
| NGINX Ingress Controller | `kubectl get ingressclass nginx` |
| Helm 4 | `helm version` |
| kubectl (built-in Kustomize) | `kubectl version --client` |
| Istio (only for prod) | `kubectl get pods -n istio-system` |
| `openssl` | creates the self-signed TLS secret for each host |

```bash
kubectl config use-context kind-dso202
kubectl get nodes
helm version
kubectl version --client
```
![alt text](<Evidences/Screenshot from 2026-11-03 22-06-17.png>)

> **Clean start.** Assignment 2 used namespace `dso202-assignment-02` and host `tasktracker.local`. The new environments use their own namespaces, so nothing collides. If the memory of the kind node is tight, remove the old namespace first: `make -C ../assignment-2 cleanup`.

---

## 3. Part A - Kustomize

### 3.1 What went into the base and what went into the overlays

| Belongs in the **base** (identical everywhere) | Belongs in an **overlay** (differs per environment) |
|---|---|
| StatefulSet, Deployments, Services, probes, ServiceAccounts, Roles, Ingress structure | `namespace:` |
| Default config and secret keys, through generators | Replica counts (`replicas:`) |
| Default resource requests/limits | Image tags (`images:`) |
| | Host name (JSON 6902 patch), `CORS_ORIGIN` and password (generator `behavior: merge`) |
| | Prod only: bigger backend limits (strategic merge patch), Istio objects, edge-to-mesh Ingress annotations |

Every `metadata.namespace` was removed from the Assignment 2 manifests. The `namespace:` transformer in each overlay stamps the right namespace on every object, including the ServiceAccount subjects inside the RoleBindings.

### 3.2 The files

**`kustomize/base/kustomization.yaml`** composes the resources and generates the ConfigMap and Secret from `config.env` and `secret.env`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - rbac.yaml
  - database.yaml
  - backend.yaml
  - frontend.yaml
  - ingress.yaml

generatorOptions:
  disableNameSuffixHash: true

configMapGenerator:
  - name: task-tracker-config
    envs:
      - config.env

secretGenerator:
  - name: task-tracker-secret
    envs:
      - secret.env
```

Why the name hash is switched off here (the lectures call this exceptional, so it needs a reason): `rbac.yaml` pins the ConfigMap with `resourceNames: ["task-tracker-config"]`, and the Assignment 2 TaskBackup operator looks the Secret up by the fixed name `task-tracker-secret`. A hash suffix would break both. References inside the Pod templates would have been rewritten automatically; these two would not.

**`kustomize/overlays/dev/kustomization.yaml`** (staging and prod have the same shape with their own values):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - namespace.yaml

namespace: dso202-dev

labels:
  - pairs:
      app.kubernetes.io/environment: dev
    includeSelectors: false      # never touch selectors: Deployment selectors are immutable
    includeTemplates: true

replicas:
  - name: backend
    count: 1
  - name: frontend
    count: 1

images:
  - name: sarojsanyasi/dso202-backend
    newTag: "1.0"
  - name: sarojsanyasi/dso202-frontend
    newTag: "1.0"

generatorOptions:
  disableNameSuffixHash: true

configMapGenerator:
  - name: task-tracker-config
    behavior: merge              # keep the base keys, change only CORS_ORIGIN
    literals:
      - CORS_ORIGIN=https://dev.tasktracker.local

secretGenerator:
  - name: task-tracker-secret
    behavior: merge
    literals:
      - DB_PASSWORD=DevPass2026
      - POSTGRES_PASSWORD=DevPass2026

patches:
  - path: patch-ingress-host.yaml
    target:
      kind: Ingress
```

**`patch-ingress-host.yaml`** is a **JSON 6902** patch (exact paths), applied to both Ingress objects:

```yaml
- op: replace
  path: /spec/rules/0/host
  value: dev.tasktracker.local
- op: replace
  path: /spec/tls/0/hosts/0
  value: dev.tasktracker.local
```

**`overlays/prod/patch-resources.yaml`** is a **strategic merge** patch ("speaks Kubernetes"): it names the `backend` container and changes only its resources.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: 500m, memory: 256Mi}
```

**Choosing the patch style** (lecture rule: *strategic merge speaks Kubernetes, JSON 6902 speaks paths*): the resources change is a Kubernetes-shaped fragment on a named container, so strategic merge is the readable choice. The host change is two exact paths, and the Istio principals change in prod (below) replaces two exact list entries, so JSON 6902 is the precise choice.

**`overlays/prod/kustomization.yaml`** adds the mesh and two more patches:

```yaml
resources:
  - ../../base
  - ../../istio            # PeerAuthentication STRICT, deny-all, allow rules, DR, VS
  - namespace.yaml         # carries istio-injection: enabled

patches:
  - path: patch-resources.yaml
  - path: patch-ingress-mesh.yaml        # service-upstream + upstream-vhost annotations
  - target:
      kind: AuthorizationPolicy
      name: db-allow-backend-and-backups
    patch: |-
      - op: replace
        path: /spec/rules/0/from/0/source/principals/0
        value: cluster.local/ns/dso202-prod/sa/backend-sa
      - op: replace
        path: /spec/rules/0/from/0/source/principals/1
        value: cluster.local/ns/dso202-prod/sa/taskbackup-runner
```

The Istio files use short host names (`backend-svc`), which resolve inside whichever namespace the overlay selects. Only the SPIFFE principals contain a namespace, so that is the one thing prod patches.

Patches are listed in a fixed order and none of them writes the same field, so there is no "patch onion".

### 3.3 Render first: rendered YAML is the truth

```bash
cd assignment-3/kustomize
kubectl kustomize overlays/dev     > /tmp/dev.yaml
kubectl kustomize overlays/staging > /tmp/staging.yaml
kubectl kustomize overlays/prod    > /tmp/prod.yaml
grep -c '^kind:' /tmp/dev.yaml /tmp/staging.yaml /tmp/prod.yaml
```

Output (21 objects for dev and staging, 30 for prod, the 9 extra being the Istio objects):

```
/tmp/dev.yaml:21
/tmp/staging.yaml:21
/tmp/prod.yaml:30
```
![alt text](<Evidences/Screenshot from 2026-11-03 22-08-06.png>)

Check that each overlay changed only what it should:

```bash
for e in dev staging prod; do
  echo "== $e"
  grep -E '^  replicas:|namespace:|host: .*tasktracker|CORS_ORIGIN' /tmp/$e.yaml | sort | uniq -c
done
```
![alt text](<Evidences/Screenshot from 2026-11-03 22-08-50.png>)

Compare two environments side by side. Only the intended lines differ:

```bash
diff <(kubectl kustomize overlays/dev) <(kubectl kustomize overlays/prod) | head -60
```
![alt text](<Evidences/Screenshot from 2026-11-03 22-09-31.png>)

### 3.4 Deploy dev with the safe command sequence

The Ingress needs its TLS secret, so the namespace is created first and the secret second. (`kubectl apply -k` creates the namespace as part of the overlay, so the order is: apply, add the secret, wait.)

```bash
cd assignment-3

# 1. render        2. server-side diff        3. apply
kubectl kustomize kustomize/overlays/dev | head -30
kubectl diff -k kustomize/overlays/dev | head -30
kubectl apply -k kustomize/overlays/dev
```

![alt text](<Evidences/Screenshot from 2026-11-03 22-17-58.png>)

```bash
# TLS secret for the dev host (self-signed)
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /tmp/dev.key -out /tmp/dev.crt \
  -subj "/CN=dev.tasktracker.local/O=DSO202" \
  -addext "subjectAltName=DNS:dev.tasktracker.local"
kubectl create secret tls tasktracker-tls --cert=/tmp/dev.crt --key=/tmp/dev.key -n dso202-dev
rm -f /tmp/dev.key /tmp/dev.crt

# 4. verify
kubectl rollout status statefulset/db -n dso202-dev --timeout=300s
kubectl rollout status deployment/backend  -n dso202-dev --timeout=300s
kubectl rollout status deployment/frontend -n dso202-dev --timeout=300s
kubectl get statefulset,deployment,pod,svc,pvc,ingress -n dso202-dev
```

Expected: `db-0` Running, `backend` 1/1, `frontend` 1/1, PVC `data-db-0` Bound, two Ingresses with host `dev.tasktracker.local`.

![alt text](<Evidences/Screenshot from 2026-11-03 22-19-20.png>)

![alt text](<Evidences/Screenshot from 2026-11-03 22-19-41.png>)

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8443:443 &
curl -sk --resolve dev.tasktracker.local:8443:127.0.0.1 https://dev.tasktracker.local:8443/backend/api/status
```
![alt text](<Evidences/Screenshot from 2026-11-03 23-08-02.png>)

### 3.5 Deploy staging and show that the overlays are independent

```bash
kubectl apply -k kustomize/overlays/staging
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /tmp/st.key -out /tmp/st.crt \
  -subj "/CN=staging.tasktracker.local/O=DSO202" \
  -addext "subjectAltName=DNS:staging.tasktracker.local"
kubectl create secret tls tasktracker-tls --cert=/tmp/st.crt --key=/tmp/st.key -n dso202-staging
rm -f /tmp/st.key /tmp/st.crt
kubectl rollout status deployment/backend -n dso202-staging --timeout=300s
kubectl get deploy -n dso202-dev
kubectl get deploy -n dso202-staging
```

Expected: dev has 1/1 replicas, staging has 2/2. Two environments run side by side from one base.

![alt text](<Evidences/Screenshot from 2026-11-03 23-09-49.png>)

### 3.6 Prove "change the base once, every environment follows"

Add one environment-independent change to the **base only** (an annotation on the backend Deployment) and render all three overlays:

```bash
cd kustomize
# add to base/backend.yaml under metadata:  annotations: {dso202/owner: platform-team}
sed -i '0,/^  labels:/s//  annotations:\n    dso202\/owner: platform-team\n  labels:/' base/backend.yaml
for e in dev staging prod; do echo -n "$e: "; kubectl kustomize overlays/$e | grep -c 'dso202/owner'; done
```

Expected: `1` for each environment. One edit, three environments updated, no copy-paste, no drift. Revert it with `git checkout base/backend.yaml` (or remove the two lines).

![alt text](<Evidences/Screenshot from 2026-11-03 23-11-22.png>)
### 3.7 Prod (mesh) and cleanup

Istio must be installed (see Assignment 2). Then:

```bash
kubectl apply -k kustomize/overlays/prod
kubectl get peerauthentication,authorizationpolicy,destinationrule,virtualservice -n dso202-prod
kubectl get pods -n dso202-prod        # READY 2/2: the Istio sidecar was injected
```

![alt text](<Evidences/Screenshot from 2026-11-03 23-26-25.png>)

Clean up before the Helm part so the same namespaces and host names can be reused:

```bash
kubectl delete -k kustomize/overlays/prod
kubectl delete -k kustomize/overlays/staging
kubectl delete -k kustomize/overlays/dev
kubectl get ns | grep dso202
```
![alt text](<Evidences/Screenshot from 2026-11-03 23-28-24.png>)

> PVCs are kept by design (`whenDeleted: Retain`). Deleting a namespace removes them, and `kubectl delete -k` deletes the Namespace object that the overlay owns.

---

## 4. Part B - Helm

### 4.1 Chart design

The chart `task-tracker` (chart version `0.1.0`, `appVersion: "1.0"`) contains the same objects as the Kustomize base. Everything that varies is a **value**:

| Value | Used for | dev | staging | prod |
|---|---|---|---|---|
| `environment` | required; label `app.kubernetes.io/environment` | dev | staging | prod |
| `host` | Ingress host, TLS host, `CORS_ORIGIN` | `dev.tasktracker.local` | `staging.tasktracker.local` | `tasktracker.local` |
| `backend.replicaCount` / `frontend.replicaCount` | Deployment replicas | 1 / 1 | 2 / 2 | 3 / 3 |
| `backend.resources` | backend limits | default | default | 100m/128Mi to 500m/256Mi |
| `secret.dbPassword` | Secret (no default) | demo | demo | demo |
| `istio.enabled` | renders `templates/istio.yaml`, adds mesh annotations to Ingress | false | false | true |

Techniques from the lectures used in the chart:

| Technique | Where | Why |
|---|---|---|
| `required` | `_helpers.tpl` (`environment`), `secret.yaml` (`dbPassword`) | no object is produced without an environment or a password |
| `include` + `nindent` | every template | reusable labels, correct indentation |
| `toYaml ... \| nindent` | resources blocks | resources come from values |
| Checksum annotations | `backend.yaml`, `frontend.yaml`, `database.yaml` | a ConfigMap or Secret change changes the Pod template, so the Pods roll out |
| Image tag defaults to `.Chart.AppVersion` | `_helpers.tpl` | upgrading the app means one field in `Chart.yaml` |
| Two label sets | common labels vs. selector labels | selectors (`app`, `tier`) are fixed and never contain changing labels |
| `if .Values.istio.enabled` | `istio.yaml`, `ingress.yaml` | optional mesh |
| `values.schema.json` | chart root | wrong types and ranges fail before any template is rendered |
| `helm.sh/hook: test` | `tests/test-connection.yaml` | `helm test` checks `{"db":"connected"}` |
| `NOTES.txt` | templates | prints how to create the TLS secret and reach the app |

Key files (full versions are in the zip):

**`Chart.yaml`**

```yaml
apiVersion: v2
name: task-tracker
description: Task Tracker (frontend, backend, PostgreSQL StatefulSet, Ingress, RBAC, optional Istio policy) for DSO202 Assignment 3
type: application
version: 0.1.0
appVersion: "1.0"
kubeVersion: ">=1.30.0-0"
```

**`values-prod.yaml`**

```yaml
environment: prod
host: tasktracker.local
secret:
  dbPassword: ProdPass2026     # demo only; real systems pass it from a secret manager
backend:
  replicaCount: 3
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits:   {cpu: 500m, memory: 256Mi}
frontend:
  replicaCount: 3
istio:
  enabled: true
```

**`templates/_helpers.tpl`** (excerpt)

```yaml
{{- define "task-tracker.environment" -}}
{{- required "environment must be set (dev, staging or prod): use -f values-<env>.yaml" .Values.environment }}
{{- end }}

{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" . }}
app.kubernetes.io/name: {{ include "task-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/environment: {{ include "task-tracker.environment" . | quote }}
{{- end }}
```

### 4.2 Validate before installing

```bash
cd assignment-3/helm
helm lint task-tracker -f values-dev.yaml
helm lint task-tracker -f values-staging.yaml
helm lint task-tracker -f values-prod.yaml
```

Expected: `1 chart(s) linted, 0 chart(s) failed` three times (plus the informational `icon is recommended`).

![alt text](<Evidences/Screenshot from 2026-11-03 23-38-20.png>)

Render each environment (no cluster contact) and count objects:

```bash
for e in dev staging prod; do
  echo -n "$e: "
  helm template tt-$e task-tracker -f values-$e.yaml -n dso202-$e | grep -c '^kind:'
done
helm template tt-dev task-tracker -f values-dev.yaml -n dso202-dev -s templates/backend.yaml | head -40
```

![alt text](<Evidences/Screenshot from 2026-11-03 23-43-34.png>)

**Four deliberate failures**, to show that each check catches a different class of error:

```bash
# 1) no environment file -> the `required` guard stops rendering
helm template tt-x task-tracker
# Error: execution error ... environment must be set (dev, staging or prod): use -f values-<env>.yaml

# 2) no password -> the `required` guard in secret.yaml
helm template tt-x task-tracker --set environment=dev
# Error: execution error ... secret.dbPassword must be set (...)

# 3) wrong type / out of range -> values.schema.json
helm template tt-x task-tracker -f values-dev.yaml --set backend.replicaCount=three
# Error: values don't meet the specifications of the schema(s) ... got string, want integer
helm template tt-x task-tracker -f values-dev.yaml --set environment=test --set backend.replicaCount=0
# - at '/environment': value must be one of '', 'dev', 'staging', 'prod'
# - at '/backend/replicaCount': minimum: got 0, want 1

# 4) server-side dry run against the real API server
helm install tt-dev task-tracker -f values-dev.yaml -n dso202-dev --create-namespace --dry-run=server | head -8
```
![alt text](<Evidences/Screenshot from 2026-11-03 23-54-38.png>)
### 4.3 Install dev and verify the release

```bash
helm install tt-dev task-tracker -f values-dev.yaml \
  -n dso202-dev --create-namespace --rollback-on-failure --wait --timeout 5m
```

Expected: `STATUS: deployed`, `REVISION: 1`, followed by the NOTES block.

![alt text](<Evidences/Screenshot from 2026-11-03 23-56-06.png>)

The Ingress needs its TLS secret (the NOTES print this command). `--wait` does not depend on it, because the Ingress is only an object that the controller reads.

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /tmp/dev.key -out /tmp/dev.crt \
  -subj "/CN=dev.tasktracker.local/O=DSO202" \
  -addext "subjectAltName=DNS:dev.tasktracker.local"
kubectl create secret tls tasktracker-tls --cert=/tmp/dev.crt --key=/tmp/dev.key -n dso202-dev
rm -f /tmp/dev.key /tmp/dev.crt

helm list -n dso202-dev
helm status tt-dev -n dso202-dev
kubectl get statefulset,deployment,pod,svc,pvc,ingress -n dso202-dev
```

![alt text](<Evidences/Screenshot from 2026-11-03 23-57-01.png>)

```bash
curl -sk --resolve dev.tasktracker.local:8443:127.0.0.1 https://dev.tasktracker.local:8443/backend/api/status
helm test tt-dev -n dso202-dev
```

Expected:

```
{"status":"ok","db":"connected"}
...
Phase:          Succeeded
```

![alt text](<Evidences/Screenshot from 2026-11-03 23-58-50.png>)
Inspect what Helm recorded (the lectures stress that `helm get` reads the release record, not the live objects):

```bash
helm get values tt-dev -n dso202-dev
helm get values tt-dev -n dso202-dev --all | head -20
helm get manifest tt-dev -n dso202-dev | grep -E '^# Source|^kind:'
kubectl get secrets -n dso202-dev --show-labels | grep sh.helm.release
```

The last command shows `sh.helm.release.v1.tt-dev.v1`: the release record is a Secret in the release's namespace. Note that it also contains the values, including the password, which is why real credentials must not be passed this way (see section 6).

![alt text](<Evidences/Screenshot from 2026-11-03 23-59-28.png>)

### 4.4 Upgrade, config-triggered rollout, history, rollback

**Upgrade with a values change.** Increase the dev backend to 2 replicas. Every upgrade passes the complete values file (`-f`), so nothing from the install is lost. (Passing only a `--set` would silently reset every other value to the chart default.)

```bash
helm upgrade tt-dev task-tracker -f values-dev.yaml -n dso202-dev \
  --set backend.replicaCount=2 --rollback-on-failure --wait
kubectl get deploy backend -n dso202-dev
```

![alt text](<Evidences/Screenshot from 2026-11-04 00-07-54.png>)

**Config change causes a rollout (checksum annotation).** Changing the CORS origin changes the ConfigMap, therefore the checksum, therefore the Pod template:

```bash
kubectl get pods -n dso202-dev -l tier=backend -o name
helm upgrade tt-dev task-tracker -f values-dev.yaml -n dso202-dev \
  --set backend.replicaCount=2 --set host=dev2.tasktracker.local --wait
kubectl get pods -n dso202-dev -l tier=backend -o name     # new Pod names: rollout happened
helm history tt-dev -n dso202-dev
```

Expected: the backend Pod names change after the second upgrade, and `helm history` lists revisions 1, 2, 3 (`superseded`, `superseded`, `deployed`). This is the same chain the lectures describe for Kustomize generators (*content changes, hash changes, Pod template changes, rollout*), implemented here with `sha256sum` instead of a generated name.

![alt text](<Evidences/Screenshot from 2026-11-04 00-12-04.png>)

**Rollback.**

```bash
helm rollback tt-dev 1 -n dso202-dev --wait
helm history tt-dev -n dso202-dev
helm get values tt-dev -n dso202-dev
kubectl get deploy backend -n dso202-dev
```

Expected: a **new** revision 4 with description `Rollback to 1`; revisions 2 and 3 stay in the history. Backend back to 1 replica and the host back to `dev.tasktracker.local`.

![alt text](<Evidences/Screenshot from 2026-11-04 00-16-07.png>)
**A failed upgrade rolls itself back.** Use an image tag that does not exist:

```bash
helm upgrade tt-dev task-tracker -f values-dev.yaml -n dso202-dev \
  --set backend.image.tag=does-not-exist --rollback-on-failure --wait --timeout 90s
helm history tt-dev -n dso202-dev | tail -3
kubectl get pods -n dso202-dev -l tier=backend
```

Expected: `Error: UPGRADE FAILED ... timed out waiting for the condition`, then Helm restores the last good revision, and the original Pods are still `Running` (the broken Pod never became Ready, so the rolling update never removed the healthy one).

![alt text](<Evidences/Screenshot from 2026-11-04 00-20-10.png>)

### 4.5 Staging and prod with the same chart

```bash
helm upgrade --install tt-staging task-tracker -f values-staging.yaml \
  -n dso202-staging --create-namespace --rollback-on-failure --wait --timeout 5m

# prod needs Istio installed (Assignment 2). The chart adds the mesh objects when istio.enabled=true.
kubectl create namespace dso202-prod --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace dso202-prod istio-injection=enabled --overwrite
helm upgrade --install tt-prod task-tracker -f values-prod.yaml \
  -n dso202-prod --rollback-on-failure --wait --timeout 5m

helm list -A | grep tt-
kubectl get peerauthentication,authorizationpolicy,destinationrule,virtualservice -n dso202-prod
kubectl get pods -n dso202-prod
```

Expected: three releases (`tt-dev`, `tt-staging`, `tt-prod`) from one chart; staging has 2/2 replicas; prod has 3/3, nine Istio objects, and Pods are `2/2` (application + sidecar).

![alt text](<Evidences/Screenshot from 2026-11-04 00-21-46.png>)

Prove the production RBAC and mesh rules still hold (same checks as Assignment 2):

```bash
kubectl auth can-i patch deployment/backend --as=system:serviceaccount:dso202-prod:ci-deployer -n dso202-prod   # yes
kubectl auth can-i delete deployment/backend --as=system:serviceaccount:dso202-prod:ci-deployer -n dso202-prod  # no
kubectl auth can-i get secrets --as=dev@cst.edu.bt --as-group=dso202-developers -n dso202-prod                  # no
kubectl auth can-i list pods --as=auditor@cst.edu.bt -n dso202-prod                                              # yes
```

![alt text](<Evidences/Screenshot from 2026-11-04 00-41-52.png>)

### 4.6 Package the chart and clean up

```bash
helm package task-tracker
ls -l task-tracker-0.1.0.tgz
helm show chart ./task-tracker-0.1.0.tgz

helm uninstall tt-prod    -n dso202-prod
helm uninstall tt-staging -n dso202-staging
helm uninstall tt-dev     -n dso202-dev
helm list -A
kubectl delete namespace dso202-dev dso202-staging dso202-prod --ignore-not-found
```

![alt text](<Evidences/Screenshot from 2026-11-04 00-43-16.png>)

---

## 5. Kustomize vs Helm on this application

| Aspect | Kustomize (this repo) | Helm (this repo) |
|---|---|---|
| Source files | Valid Kubernetes YAML, readable and applyable on their own | Templates, not valid YAML until rendered |
| Per-environment input | Overlay directory with patches and generators | One `values-<env>.yaml` file |
| Where the base lives | `base/` (plain resources) | `templates/` + `values.yaml` |
| Preview | `kubectl kustomize`, `kubectl diff -k` | `helm template`, `--dry-run=server`, `helm lint` |
| Input validation | None built in; the API server rejects bad fields at apply time | `required` and `values.schema.json` reject bad input before rendering |
| History and rollback | None; revert the Git commit and re-apply | Numbered revisions, `helm rollback`, `--rollback-on-failure` |
| Optional parts (Istio) | A separate directory an overlay includes | `if .Values.istio.enabled` |
| Roll Pods on config change | Generated name hash (disabled here for a stated reason) | `checksum/config` annotation |
| Packaging and sharing | Git directory | Versioned `.tgz` chart |
| Built into kubectl | Yes (`-k`) | No, separate binary |

**When I would use which.** Kustomize is the better fit when a team owns the YAML and only needs per-environment variants: the files stay plain Kubernetes and the diff between environments is tiny and reviewable. Helm is the better fit when the application is delivered as a package to others, when input must be validated, or when release history and automatic rollback matter. They also combine: install a third-party chart with Helm and apply organisation-specific patches with Kustomize.

---

## 6. Security notes

- Kubernetes Secrets here are base64 **encoding**, not encryption. The demo passwords in `secret.env` and `values-*.yaml` are dummy values for the assignment. Real credentials must come from a secret manager (Sealed Secrets, External Secrets, Vault) and not from Git.
- Helm stores every supplied value, including the password, in the release record Secret (`sh.helm.release.v1.*`). Anyone allowed to read Secrets in that namespace can recover it with `helm get values`.
- The TLS private key is generated per environment with `openssl` and loaded straight into the cluster. It is never committed.
- `includeSelectors: false` is used in every Kustomize label block: adding labels to selectors would change an immutable Deployment selector and a Service's traffic routing.
- RBAC from Assignment 2 is unchanged: no app ServiceAccount has API access, developers cannot read Secrets, and the CI account can patch only the named workloads.

---

## 7. Scope and what was reused from Assignment 2

| Item | Treatment |
|---|---|
| StatefulSet database, Services, probes, Ingress rules, RBAC personas, Istio policy | Re-expressed as a Kustomize base + overlays and as a Helm chart. Behaviour is unchanged. |
| Container images (`sarojsanyasi/dso202-db`, `-backend`, `-frontend`) | Reused as is. Helm and Kustomize do not build images. |
| TaskBackup Operator (CRD + controller) | Not repackaged. A CRD is cluster-scoped and shared by every environment, so it stays a one-time platform install (`make operator` in Assignment 2). The `taskbackup-runner` ServiceAccount and the Istio rule that admits it are included here. |
| Platform setup (kind, ingress-nginx, Istio) | Same as Assignment 2. |

---

## 8. Review answers

**Kustomize**

1. *What belongs in a base, and what in an overlay?* The base holds what every environment shares (workload structure, Services, RBAC, default config). An overlay holds only what differs (namespace, replicas, image tags, host, passwords, extra objects such as the Istio policy).
2. *Does Kubernetes store `kustomization.yaml`?* No. It is a build instruction. Kustomize renders ordinary Kubernetes YAML, and only that reaches the API server.
3. *What does `kubectl apply -k DIR` do?* It renders the kustomization in `DIR` and applies the result. `-k` takes a directory containing a `kustomization.yaml`, not a YAML file.
4. *Why inspect the rendered YAML first?* The rendered output is what the cluster receives. Debugging only the overlay hides mistakes such as a patch that matched the wrong object, or a namespace that was not applied.
5. *Why is `includeSelectors: true` risky?* It writes the label into selectors. Deployment selectors are immutable, Service selectors decide traffic routing, and policy selectors decide who is allowed. Changing them everywhere at once changes semantics.
6. *Why did the name hash get disabled, and is that a problem?* Fixed names are pinned in `resourceNames` (RBAC) and by the operator. It is a documented exception. The cost is that a ConfigMap change no longer triggers a rollout by itself. The alternative would be to keep the hash and patch those two fixed references.
7. *Strategic merge or JSON 6902?* Strategic merge for the Kubernetes-shaped resources change on a named container. JSON 6902 for exact path replacements (host names, Istio principals).

**Helm**

1. *What is the difference between a chart, a release and a revision?* A chart is the package. A release is one installation of it in one namespace (`tt-dev`). A revision is a numbered snapshot of a release, created by every install, upgrade and rollback.
2. *Why does `helm rollback tt-dev 1` produce revision 4 and not revision 1?* Rollback appends a new revision that copies revision 1; history is never rewritten.
3. *Why must every upgrade pass the full values file?* An upgrade given any value flag starts from the chart defaults and applies only the values in that command, silently discarding earlier overrides. Keeping all values in version-controlled `-f` files avoids it.
4. *Why does `helm lint` alone not suffice?* It reports a missing required value only as a warning and does not check Kubernetes field schemas. CI has to render each environment (`helm template`) and, against a cluster, run a server-side dry run.
5. *What does the checksum annotation do?* It hashes the rendered ConfigMap and Secret into the Pod template, so a config change produces a new Pod template and a rolling update. Without it, a ConfigMap change never restarts Pods.
6. *What is `--rollback-on-failure`?* The Helm 4 name of `--atomic`: a failed install is removed and a failed upgrade is rolled back to the last successful revision.
7. *Does Helm keep secrets secret?* No. Values are stored in the release record, readable by anyone who can read Secrets in that namespace.

---

## 9. Command summary

```bash
# Kustomize
kubectl kustomize kustomize/overlays/<env>        # render
kubectl diff  -k kustomize/overlays/<env>         # what would change
kubectl apply -k kustomize/overlays/<env>         # apply
kubectl delete -k kustomize/overlays/<env>        # remove

# Helm
helm lint task-tracker -f values-<env>.yaml
helm template tt-<env> task-tracker -f values-<env>.yaml -n dso202-<env>
helm upgrade --install tt-<env> task-tracker -f values-<env>.yaml -n dso202-<env> --create-namespace --rollback-on-failure --wait
helm test tt-<env> -n dso202-<env>
helm history tt-<env> -n dso202-<env>
helm rollback tt-<env> <revision> -n dso202-<env>
helm uninstall tt-<env> -n dso202-<env>
```
# AS2025_DSO202_02230289_assignment-3
