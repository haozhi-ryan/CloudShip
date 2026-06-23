# Restarting Your Local Kubernetes Environment

This doc covers exactly what to run to get CloudShip's app + Prometheus/Grafana monitoring stack back up, depending on how your last session ended.

---

## Quick Reference — just want to open Grafana right now?

> **Note:** port-forwarding is *not* persistent — it only survives as long as the terminal running it stays open. You'll need to re-run the port-forward command **every single session**, even if you just did `minikube stop` / `minikube start` and everything else came back instantly. This is true regardless of which Situation (A or B) below you're in.

Assuming the cluster is already running (`minikube start` done, `kubectl get pods -n monitoring` shows everything `Running`):

**1. Get the admin password** (run this, copy the output):

```bash
kubectl --namespace monitoring get secrets monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

**2. Open a port-forward** (run this, leave the terminal open/running):

```bash
kubectl --namespace monitoring port-forward svc/monitoring-grafana 3000:80
```

**3. Log in:**
- URL: `http://localhost:3000`
- Username: `admin`
- Password: whatever step 1 printed out

To stop the port-forward later, go back to that terminal and press `Ctrl+C`.

### Prometheus's own UI (optional, for raw queries / checking target health)

Grafana is the dashboard layer — but Prometheus also has its own basic web UI, useful for checking whether everything Prometheus *should* be scraping is actually `UP`, or for running raw queries that Grafana's pre-built dashboards don't cover.

```bash
kubectl --namespace monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Visit `http://localhost:9090` — no login required.

- **Status → Targets**: shows every scrape target and whether it's `UP` or `DOWN`. First place to check if a metric seems to be missing from Grafana.
- **Graph tab**: type a query like `up` and hit Execute — returns `1` for healthy targets, `0` for failing ones.

Same rule applies: this port-forward needs to be re-run every session too, and it needs its own terminal, separate from Grafana's port-forward (they're two different processes on two different ports).

---

## Quick decision: which situation am I in?

| You ran... | What survives | What you need to redo |
|---|---|---|
| `minikube stop` | Cluster state, cached images, Helm release, all pods/config | Nothing — just restart |
| `minikube delete` | Nothing (full wipe) | Everything — rebuild from scratch |
| Computer restart only (no stop/delete) | Same as `minikube stop` *(see note below)* | Nothing, as long as Docker Desktop comes back up normally |

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
```

**Expected result:** everything should already show `Running` within a few seconds to a minute — no re-pulling, no re-installing. This is exactly where you left off.

If anything shows `Pending` or `ContainerCreating` for an unusually long time even on this path, see the **Troubleshooting** section at the bottom — it's likely a transient network hiccup, not a sign you need to rebuild anything.

### Accessing things after `minikube start`

**Your app:**

```bash
minikube service cloudship-service
```

**Grafana:** see the **Quick Reference** section at the top of this doc for the password and port-forward commands.

---

## Situation B: You ran `minikube delete` (or are starting completely fresh)

Full rebuild. Nothing is cached — this redoes everything from Week 5 onward.

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

### 3. Reapply your app's Deployment and Service

```bash
# From wherever deployment.yaml and service.yaml live
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods
kubectl get services
```

### 4. Reinstall the monitoring stack via Helm

If Helm itself isn't installed (only relevant if you also wiped your WSL2 environment, not just minikube):

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

Add the chart repo (safe to run even if already added — it'll just say "already exists"):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Install the stack:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
```

### 5. Watch it come up

```bash
kubectl get pods -n monitoring -w
```

Expect this to take a while — first-time installs pull ~6 images (Prometheus, Grafana, Alertmanager, the operator, node-exporter, kube-state-metrics) and some registries (`quay.io`, `registry.k8s.io`) can be slow or flaky depending on network conditions. Use Ctrl+C to stop watching once everything shows `Running`.

### 6. Access everything

Same commands as Situation A's "Accessing things" section above — app via `minikube service cloudship-service`, Grafana via `port-forward` on `svc/monitoring-grafana`.

---

## Troubleshooting: a pod is stuck `ContainerCreating` / `ImagePullBackOff`

This happened a few times during the first install — usually a transient registry/network issue, not a config problem.

**Step 1 — check what's actually happening:**

```bash
kubectl describe pod -n monitoring <pod-name>
```

Look at the `Events` section at the bottom.

- If you see repeating `Pulling` → `Failed` → `BackOff` cycles, it's actively retrying — often just needs more time (a few minutes).
- If you see a single `Pulling` event with **no follow-up for 5+ minutes**, the pull has likely silently hung — this needs manual intervention (next step), since waiting won't fix it.

**Step 2 — force a fresh attempt:**

```bash
kubectl delete pod -n monitoring <pod-name> --force --grace-period=0
```

The controlling Deployment/StatefulSet/ReplicaSet will recreate the pod automatically with a clean pull attempt.

**Step 3 — if multiple pods keep silently hanging (not just failing-and-retrying):**

Restart minikube's network stack — this clears stale Docker networking state without losing cached images:

```bash
minikube stop
minikube start
```

Then re-check:

```bash
kubectl get pods -n monitoring
```

**Step 4 — if you suspect DNS specifically** (symptom: long silent hangs rather than clean errors):

```bash
minikube ssh -- "cat /etc/resolv.conf"
minikube ssh -- "time nslookup quay.io"
minikube ssh -- "time nslookup registry.k8s.io"
```

A slow or failed `nslookup` confirms DNS resolution inside minikube's container is the bottleneck.

---

## Useful status checks, any time

```bash
minikube status              # is the cluster up at all?
kubectl get nodes             # is the node Ready?
kubectl get pods              # your app
kubectl get pods -n monitoring  # the monitoring stack
helm list -n monitoring       # is the Helm release healthy ("deployed", not "failed")?
```