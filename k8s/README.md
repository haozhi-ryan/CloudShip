# Kubernetes Manifests (`deployment.yaml`, `service.yaml`)

## What these files do

These two files define how CloudShip's Next.js app runs on a Kubernetes cluster (currently **minikube**, running locally). Unlike the Terraform files, these aren't applied with `terraform apply` — they're applied directly to the cluster with `kubectl apply -f <file>`, since they speak the Kubernetes API, not AWS's API.

### `deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudship-deployment
  labels:
    app: cloudship
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudship
  template:
    metadata:
      labels:
        app: cloudship
    spec:
      containers:
        - name: cloudship-app
          image: cloudship-app:local
          imagePullPolicy: Never
          ports:
            - containerPort: 3000
```

| Field | Purpose |
|---|---|
| `replicas: 2` | How many identical copies (pods) of the app should be running at once. The Deployment continuously works to keep this number true — if a pod crashes or is deleted, a replacement is scheduled automatically. |
| `selector.matchLabels` | Tells the Deployment which pods belong to it — any pod carrying the label `app: cloudship`. This must exactly match `template.metadata.labels` below it, or the Deployment won't recognize its own pods. |
| `template` | The blueprint for each pod replica — not a pod itself, but the spec used to create one each time the Deployment needs a new copy. |
| `image: cloudship-app:local` | The Docker image to run. `:local` is a tag you chose when building the image — it isn't pulled from a registry like ECR, it's expected to already exist inside the cluster. |
| `imagePullPolicy: Never` | Tells Kubernetes "don't try to download this image from anywhere — use what's already loaded into the cluster." Required for local minikube work, since the image was loaded manually via `minikube image load`, not pulled from ECR. This line goes away once the app deploys against a real registry. |
| `containerPort: 3000` | The port the Next.js app listens on **inside the container**. This is documentation/metadata for Kubernetes — it doesn't by itself expose anything outside the pod. That's the Service's job. |

### `service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cloudship-service
spec:
  type: NodePort
  selector:
    app: cloudship
  ports:
    - port: 80
      targetPort: 3000
      protocol: TCP
```

| Field | Purpose |
|---|---|
| `type: NodePort` | Exposes the app on a port on the node itself, reachable from your host machine via `minikube service`. This type is appropriate for local testing; production clusters (e.g. EKS) typically use `LoadBalancer` or an `Ingress` instead, neither of which apply to a single-node local cluster. |
| `selector: app: cloudship` | Determines which pods receive traffic sent to this Service. Must match the label on the pods created by the Deployment — if this value is wrong or typo'd, the Service silently finds zero matching pods and traffic goes nowhere. |
| `port: 80` | The port the Service itself listens on, inside the cluster's internal network. |
| `targetPort: 3000` | The port traffic gets forwarded to once it reaches a pod — must match `containerPort` in `deployment.yaml`. |

### A note on file location

These files don't need their own folder, and Kubernetes has no opinion on where they live — `kubectl apply -f path/to/file.yaml` works regardless of directory structure. They can sit flat in the project root, alongside `Dockerfile`, or in a `k8s/` subfolder if you'd rather keep cluster config visually separate from app code. This is purely an organizational choice, not a technical requirement (unlike Terraform, which cares about which files live in which working directory because that determines state scope).

---

## The simple version (beginner analogy)

Think of the Deployment as a **restaurant manager**, and the Service as the **restaurant's phone number**.

- **The Deployment (manager)** has one job: make sure exactly the right number of chefs (pods) are working at all times. You told the manager "I always want 2 chefs on shift." If a chef calls in sick (a pod crashes), the manager immediately hires a replacement — you never have to ask. The manager doesn't cook anything themselves; they just make sure the right number of identical, capable chefs are always present, each one following the same recipe card (`template`).

- **The label (`app: cloudship`)** is each chef's uniform. The manager only counts and manages chefs wearing this uniform — it's how they tell "my chefs" apart from anyone else who might be in the building.

- **The Service (phone number)** is the one number customers call to place an order. Customers never call a specific chef directly — chefs come and go (pods get replaced), but the restaurant's phone number never changes. When a call comes in, it gets routed to *whichever* chef in the right uniform is currently available. If the manager accidentally tells the phone system to route calls to chefs wearing the wrong uniform (a label/selector typo), every call goes unanswered — the chefs are right there cooking, but nobody is picking up the phone for them.

- **`imagePullPolicy: Never`** is like telling a new chef "don't go to the supplier to get the recipe book — it's already on the shelf in the kitchen." That only works because you personally walked the recipe book into the kitchen ahead of time (`minikube image load`). Once you're using a real restaurant supply chain (a container registry like ECR), the chef can fetch the recipe themselves — this instruction goes away.

- **`NodePort`** is a *temporary, local-only* phone line — like a walkie-talkie that only works inside your own house. It's perfect for testing the kitchen at home, but customers across town can't dial in. A real, internet-reachable phone number for the restaurant (the way your ECS app has a public ALB URL) requires a different, more "public-facing" setup — which is exactly why this Service type works for minikube but wouldn't be the right choice for a cluster meant to serve real internet traffic.