# GitOps with ArgoCD

## What ArgoCD does

ArgoCD is a **GitOps controller** — a process that runs inside your Kubernetes cluster and continuously ensures the cluster matches what's declared in your Git repository. It polls your GitHub repo on a schedule (every 3 minutes by default) and automatically applies any changes it detects to the cluster.

The key shift from the previous workflow:

| Before ArgoCD | After ArgoCD |
|---|---|
| You edit a manifest → you run `kubectl apply` | You edit a manifest → you push to GitHub → ArgoCD applies it |
| Cluster state tracked in your head | Cluster state tracked in Git |
| Manual drift possible (cluster ≠ repo) | Drift detected and corrected automatically |

In CloudShip, ArgoCD watches the `k8s/` folder in the GitHub repo and syncs its contents to the local minikube cluster.

---

## How it's set up

### Installation

ArgoCD runs as its own set of pods inside a dedicated `argocd` namespace. It was installed using its official manifest:

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

The `--server-side --force-conflicts` flags are required because ArgoCD's Custom Resource Definitions (CRDs) are too large for standard client-side apply — they exceed kubectl's annotation size limit. Server-side apply moves the calculation to the cluster itself, which has no such limit.

### The Application resource

ArgoCD uses a custom Kubernetes resource called an **Application** to define what to watch and where to sync it. CloudShip's Application was created via the ArgoCD UI with these settings:

| Field | Value | Purpose |
|---|---|---|
| Application Name | `cloudship` | Identifier for this sync configuration |
| Project | `default` | ArgoCD's built-in default project — no extra config needed |
| Sync Policy | `Automatic` | ArgoCD syncs without you having to click anything |
| Repository URL | `https://github.com/haozhi-ryan/CloudShip` | Where to read manifests from |
| Revision | `HEAD` | Always track the latest commit on the default branch |
| Path | `k8s` | Only watch this subfolder — ignores everything else in the repo |
| Cluster URL | `https://kubernetes.default.svc` | "The cluster I'm already running in" — i.e. minikube |
| Namespace | `default` | Where to apply the manifests |

### Accessing the ArgoCD UI

ArgoCD exposes a web dashboard. Port-forward it to access it locally:

```bash
# Get the admin password (run once per session):
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward the UI (leave this terminal open):
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

- URL: `https://localhost:8080` (click through the self-signed certificate warning)
- Username: `admin`
- Password: output of the first command

---

## What the UI shows

| Field | What it means |
|---|---|
| **Synced** | The cluster matches what's in Git right now |
| **Healthy** | The resources ArgoCD applied (Deployment, Service) are functioning correctly — pods are running |
| **OutOfSync** | A difference exists between Git and the cluster — ArgoCD is about to fix it, or something manually changed the cluster |
| **Last Sync** | Timestamp of the most recent successful sync from GitHub |

---

## The GitOps demo — how to prove it's working

Make a change via Git and watch ArgoCD apply it without any `kubectl` commands:

1. Edit `k8s/deployment.yaml` — change `replicas: 2` to `replicas: 4`
2. Commit and push to GitHub
3. In the ArgoCD UI, click **Refresh** to force an immediate poll (or wait up to 3 minutes for the automatic poll)
4. Watch the status flip to `OutOfSync` → `Syncing` → `Synced`
5. Verify in the terminal:

```bash
kubectl get pods
```

You should see 4 pods running — without having run `kubectl apply` yourself. That's GitOps.

---

## Why this matters at scale

The value of GitOps isn't obvious in a solo portfolio project where you're the only person touching the cluster. It becomes critical when:

- **Teams are involved** — multiple engineers can't all run `kubectl apply` manually without stepping on each other. Git becomes the single source of truth with a clear audit trail of who changed what and why.
- **Disaster recovery** — if a cluster is destroyed, pointing ArgoCD at the same repo rebuilds the entire desired state automatically.
- **No direct cluster access needed** — developers push to Git and never need kubectl permissions. The GitOps controller handles the apply. This is a significant security improvement in production environments.
- **Drift detection** — if someone manually changes something on the cluster (e.g. `kubectl scale` to change replicas), ArgoCD detects the mismatch and reconciles it back to what Git says. The cluster can't silently drift from the declared state.

---

## ArgoCD vs GitHub Actions — what's the difference?

Both are automation tools triggered by Git activity, but they serve different purposes:

| | GitHub Actions | ArgoCD |
|---|---|---|
| **Trigger model** | Push-based — fires when you push | Pull-based — polls Git on a schedule |
| **What it does** | Builds, tests, pushes images to ECR | Applies Kubernetes manifests to the cluster |
| **Who runs it** | GitHub's servers | A pod inside your cluster |
| **Target** | AWS ECS Fargate | minikube (or any Kubernetes cluster) |

In CloudShip, these two pipelines are completely independent — GitHub Actions handles the ECS deployment side, ArgoCD handles the Kubernetes side.

---

## The simple version (beginner analogy)

Think of your Git repository as an **architectural blueprint** for a building, and ArgoCD as a **building inspector** who visits the site every few minutes.

Before ArgoCD, you were the builder *and* the inspector. You'd update the blueprint, then go to the site yourself and make the changes by hand (`kubectl apply`). If you forgot to visit the site after updating the blueprint, the building and the blueprint would be out of sync — and nobody would know.

ArgoCD is the inspector who shows up whether you ask them to or not. They check the blueprint (Git), walk through the building (the cluster), and if anything doesn't match — a wall in the wrong place, a room missing — they fix it on the spot. The blueprint is always the authority. If a builder makes an unauthorized change directly on the site (someone runs `kubectl scale` manually), the inspector's next visit will revert it back to what the blueprint says.

The repo isn't just documentation anymore — it's the **enforceable specification** for what the cluster must look like at all times.