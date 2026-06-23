# Restarting Your Local Kubernetes Environment

This doc covers exactly what to run to get CloudShip's full local stack back up — the app, Prometheus/Grafana monitoring, and ArgoCD GitOps — depending on how your last session ended.

---

## Quick Reference — just want everything open right now?

> **Note:** port-forwarding is *not* persistent — it only survives as long as the terminal running it stays open. You'll need to re-run every port-forward command **every single session**, even after a simple `minikube stop` / `minikube start`. Each port-forward needs its own terminal.

Assuming the cluster is already running (`minikube start` done, all pods showing `Running`):

### Grafana (monitoring dashboards)

```bash
# 1. Get the admin password:
kubectl --namespace monitoring get secrets monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# 2. Port-forward (leave this terminal open):
kubectl --namespace monitoring port-forward svc/monitoring-grafana 3000:80
```

- URL: `http://localhost:3000`
- Username: `admin`
- Password: output of step 1

### Prometheus UI (optional — raw queries and target health)

```bash
kubectl --namespace monitoring port-forward \
  svc/monitoring-kube-prometheus-prometheus 9090:9090
```

- URL: `http://localhost:9090` — no login required
- **Status → Targets**: check whether all scrape targets are `UP`
- **Graph tab**: run raw PromQL queries (e.g. `up`)

### ArgoCD UI (GitOps dashboard)

```bash
# 1. Get the admin password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# 2. Port-forward (leave this terminal open):
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

- URL: `https://localhost:8080` (click through the certificate warning — expected)
- Username: `admin`
- Password: output of step 1

---

## Quick decision: which situation am I in?

| You ran... | What survives | What you need to redo |
|---|---|---|
| `minikube stop` | Cluster state, cached images, Helm release, ArgoCD, all pods/config | Nothing — just restart |
| `minikube delete` | Nothing (full wipe) | Everything — rebuild from scratch |
| Computer restart only | Same as `minikube stop` *(see note below)* | Nothing, as long as Docker Desktop comes back up normally |

**Note on computer restarts:** A normal Windows restart does **not** wipe minikube, as long as you didn't also reset/prune Docker Desktop. Treat it the same as the `minikube stop` path below.

---

## Situation A: You ran `minikube stop`

Everything is cached and preserved. This is the fast path.

```bash
# 1. Bring the cluster back
minikube start

# 2. Confirm the node is ready
kubectl get nodes

# 3. Check your app is still there
kubectl get pods
kubectl get services

# 4. Check the monitoring stack is still there
kubectl get pods -n monitoring

# 5. Check ArgoCD is still there
kubectl get pods -n argocd
```

**Expected result:** everything should already show `Running` within a few seconds to a minute — no re-pulling, no re-installing. ArgoCD will automatically re-sync with GitHub once its pods are back up; you don't need to do anything.

Then run the port-forwards from the Quick Reference section above to access Grafana and ArgoCD.

---

## Situation B: You ran `minikube delete` (or are starting completely fresh)

Full rebuild. Nothing is cached — this redoes everything from scratch.

### 1. Start the cluster

```bash
minikube start --driver=docker
kubectl get nodes
```

### 2. Rebuild and load your app image

```bash
# From your project root, wherever your Dockerfile lives
docker build -t cloudship-app:local .
minikube image load cloudship-app:local
```

### 3. Reinstall the monitoring stack via Helm

If Helm itself isn't installed (only relevant if you also wiped your WSL2 environment):

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

Add the chart repo and install:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

Watch it come up (takes a few minutes — pulling ~6 images):

```bash
kubectl get pods -n monitoring -w
```

### 4. Reinstall ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl get pods -n argocd -w
```

Wait until all ArgoCD pods show `Running` before continuing.

### 5. Recreate the ArgoCD Application

Once ArgoCD is running, go to `https://localhost:8080` (after port-forwarding) and recreate the CloudShip Application with these settings:

| Field | Value |
|---|---|
| Application Name | `cloudship` |
| Project | `default` |
| Sync Policy | `Automatic` |
| Repository URL | `https://github.com/haozhi-ryan/CloudShip` |
| Revision | `HEAD` |
| Path | `k8s` |
| Cluster URL | `https://kubernetes.default.svc` |
| Namespace | `default` |

ArgoCD will immediately sync and apply your `k8s/` manifests — you don't need to run `kubectl apply` for the Deployment or Service manually.

### 6. Verify everything

```bash
kubectl get pods              # should show cloudship pods Running
kubectl get pods -n monitoring  # should show monitoring stack Running
kubectl get pods -n argocd      # should show ArgoCD pods Running
```

---

## Troubleshooting: a pod is stuck `ContainerCreating` / `ImagePullBackOff`

This happened a few times during the first install — usually a transient registry/network issue, not a config problem.

**Step 1 — check what's actually happening:**

```bash
kubectl describe pod -n monitoring <pod-name>
```

Look at the `Events` section at the bottom.

- Repeating `Pulling` → `Failed` → `BackOff` cycles: actively retrying — often just needs more time.
- Single `Pulling` event with no follow-up for 5+ minutes: silently hung — waiting won't fix it, force-delete it (next step).

**Step 2 — force a fresh attempt:**

```bash
kubectl delete pod -n monitoring <pod-name> --force --grace-period=0
```

The controlling Deployment/ReplicaSet recreates the pod automatically with a clean pull attempt.

**Step 3 — if multiple pods keep silently hanging:**

```bash
minikube stop
minikube start
kubectl get pods -n monitoring
```

**Step 4 — if you suspect DNS specifically** (symptom: long silent hangs rather than clean errors):

```bash
minikube ssh -- "time nslookup quay.io"
minikube ssh -- "time nslookup registry.k8s.io"
```

A slow or failed `nslookup` confirms DNS resolution inside minikube is the bottleneck.

---

## Useful status checks, any time

```bash
minikube status                 # is the cluster up at all?
kubectl get nodes               # is the node Ready?
kubectl get pods                # your app (default namespace)
kubectl get pods -n monitoring  # monitoring stack
kubectl get pods -n argocd      # ArgoCD
helm list -n monitoring         # is the Helm release healthy?
```