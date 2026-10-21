# Denovo PCE

Connection and validation runbook for the **Denovo PCE AI/SI Environment**: a six-node HarvesterOS cluster running Rancher MCM, Longhorn, NGINX/Traefik ingress, Harbor, Keycloak, and the NVIDIA GPU Operator, reachable only over a shared Tailscale tailnet.

This guide takes an engineer from zero access to a fully validated environment. Baseline values in this document were captured on **2026-10-21**.

| Document | Purpose |
|---|---|
| `README.md` | Connect, validate, troubleshoot (this file) |
| [`passwdrecovery.md`](passwdrecovery.md) | Recover SSH / password access to Harvester nodes |
| [`gpu-node-setup.md`](gpu-node-setup.md) | Install the NVIDIA driver/toolkit on a GPU node to match `hpec2n1` |

---

## Contents

1. [Environment Overview](#1-environment-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step-by-Step Connection](#3-step-by-step-connection)
4. [Validation Checklist](#4-validation-checklist)
   - [4.0 Quick Health Check](#40-quick-health-check)
   - [4.1 Environment Variables](#41-environment-variables)
   - [4.2 Network Connectivity](#42-network-connectivity)
   - [4.3 Service Health Endpoints](#43-service-health-endpoints)
   - [4.4 PostgreSQL (5432)](#44-postgresql-5432)
   - [4.5 Ingress: NGINX and Traefik](#45-ingress-nginx-and-traefik)
   - [4.6 Kubernetes Cluster Health](#46-kubernetes-cluster-health)
   - [4.7 Longhorn Storage](#47-longhorn-storage)
   - [4.8 HarvesterOS](#48-harvesteros)
   - [4.9 Rancher MCM](#49-rancher-mcm)
   - [4.10 NVIDIA GPU Operator](#410-nvidia-gpu-operator)
5. [Known Findings (2026-10-21)](#5-known-findings-2026-10-21)
6. [Troubleshooting / Escalation](#6-troubleshooting--escalation)

---

## 1. Environment Overview

### Access path

```text
Engineer device ──Tailscale──► onsite-pce-wks (jumphost, 100.94.163.6 / 192.168.2.5)
                                       │
Engineer device ──Tailscale──► pce-router (advertises 192.168.2.0/24)
                                       │
                               192.168.2.0/24  PCE network
                                       │
              ┌────────────────────────┼─────────────────────────┐
     192.168.2.100 VIP          Harvester nodes             BMCs (chassis 1)
     Rancher / Harvester /      192.168.2.111–117           192.168.2.11–13
     Harbor / Keycloak / DNS
```

### Tailnet devices

| Device | Tailscale IP | Owner | Role |
|---|---|---|---|
| `onsite-pce-wks` | 100.94.163.6 | tagged-devices | Jumphost (`wks.pce.denovo`) |
| `pce-router` | 100.120.118.75 | tagged-devices | GL.iNet subnet router, advertises `192.168.2.0/24` |
| `pce` | 100.118.240.41 | projectcoalitionedge@ | Engineer workstation (optional hop) |

### PCE network (192.168.2.0/24)

| Host | IP | Role |
|---|---|---|
| `router.pce.denovo` / `glinet.pce.denovo` | 192.168.2.1 | Gateway |
| `wks.pce.denovo` | 192.168.2.5 | Jumphost |
| `traefik.pce.denovo` | 192.168.2.99 | Traefik (see [Known Findings](#5-known-findings-2026-10-21)) |
| `rancher`, `harvester`, `registry`, `keycloak`, `fileserver`, `auth`, `server.auth`, `webserver`, `builder`, `apps`, `notary`, `kasm`, `unifi`, `netbox`, `ollama`, `webui` `.pce.denovo` | 192.168.2.100 | Harvester VIP / ingress / LoadBalancer IP |

### Harvester nodes

| Node | IP | Role | GPU | BMC |
|---|---|---|---|---|
| `hpec1n1` | 192.168.2.111 | control-plane, etcd | — | 192.168.2.11 |
| `hpec1n2` | 192.168.2.112 | worker | NVIDIA A2 ×1 | 192.168.2.12 |
| `hpec1n3` | 192.168.2.113 | control-plane, etcd | NVIDIA A40 ×1 | 192.168.2.13 |
| `hpec2n1` | 192.168.2.115 | control-plane, etcd | NVIDIA A2 ×1 | 192.168.3.11 |
| `hpec2n2` | 192.168.2.116 | worker | NVIDIA A2 ×1 | 192.168.3.12 |
| `hpec2n3` | 192.168.2.117 | worker | NVIDIA A100 PCIe 40GB ×1 | 192.168.3.13 |

### Software baseline

| Component | Version | Namespace |
|---|---|---|
| HarvesterOS | v1.7.2 | `harvester-system` |
| Kubernetes (RKE2) | v1.34.9+rke2r1 | — |
| containerd | 2.2.5-k3s2 | — |
| Kernel | 6.4.0-49-default | — |
| Rancher (embedded, Harvester) | chart 2.13.3 | `cattle-system` |
| Rancher MCM (vcluster) | vcluster 0.32.3 | `rancher-vcluster` |
| Longhorn | bundled with Harvester v1.7.2 | `longhorn-system` |
| NVIDIA GPU Operator | v26.3.3 | `gpu-operator` |
| ingress-nginx | 1.15.1 (chart 4.15.101) | `kube-system` |
| Traefik | v3.7.1 (chart 40.1.003) | `kube-system` |
| cert-manager | 1.20.2 | `cert-manager` |
| Harbor | 2.15.1 (chart 1.19.1) | `harbor-system` |
| Fleet | 0.14.3 | `cattle-fleet-system` |
| CoreDNS | 1.13.1 | `kube-system` |
| Canal CNI / Multus | v3.32.0 / 4.2.4 | `kube-system` |
| Kube-OVN operator CRD | v1.14.10 | `kube-system` |
| Metal3 | 0.15.1 | `metal3-system` |
| Hauler | 2.0.1 | `hauler-system` |
| rancher-monitoring / rancher-logging | v0.80.1 / 4.10.0 | `cattle-monitoring-system` / `cattle-logging-system` |

Rancher cluster registration: **`harvester-cluster`**, cluster ID **`c-m-rlxp8s2v`**.

---

## 2. Prerequisites

### Access

- [ ] A device on the Denovo PCE tailnet. Access is approved by the tailnet owner (**barlow**). The tailnet is shared, so you must accept the share invitation in the Tailscale admin console before devices appear.
- [ ] An SSH account on the jumphost (`wks`). Send your **public** key to barlow.
- [ ] A Rancher MCM login at `https://rancher.pce.denovo` with cluster-owner or admin on `harvester-cluster`.
- [ ] Your SSH key installed for the `rancher` user on the Harvester nodes. If not, see [`passwdrecovery.md`](passwdrecovery.md#adding-a-new-engineer).

### Local tools (engineer device)

```bash
# Tailscale — Linux
curl -fsSL https://tailscale.com/install.sh | sh
tailscale version
```

macOS: install the Tailscale app from the App Store and enable **Use Tailscale subnets** in its settings.

### Jumphost tools (`wks`)

All validation runs from `wks`. It needs `kubectl` v1.34.9 (matching the cluster), `helm`, `jq`, `curl`, and `dig`.

```bash
command -v kubectl helm jq curl dig || echo "missing tools — install below"
```

Install `kubectl` (as **barlow**; only the `install` line uses sudo):

```bash
KVER=v1.34.9
cd /tmp
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
cd ~ && kubectl version --client
```

Install `helm` and `jq`:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sudo dnf install -y jq bind-utils 2>/dev/null || sudo apt-get install -y jq dnsutils
```

> ### Work as `barlow`, not root
> The kubeconfig and SSH keys live in `/home/barlow`. As root, `~` resolves to `/root`, so `kubectl` and `ssh` silently use the wrong files. Your prompt should read `(barlow) wks:~`. If it reads `(root)`, type `exit`.

### Repository hygiene

Never commit kubeconfigs, tokens, passwords, or private keys. This repo's `.gitignore` blocks the common file names. Rancher tokens look like `kubeconfig-user-xxxxx:...`. If one is exposed, delete it under **Rancher → avatar → Account & API Keys**.

---

## 3. Step-by-Step Connection

### Step 1 — Join the tailnet and accept routes

```bash
sudo tailscale up --accept-routes
tailscale status
```

Expected: `onsite-pce-wks` and `pce-router` listed without `offline`.

If you were already connected, enable routes without re-authenticating:

```bash
sudo tailscale set --accept-routes
```

Confirm the PCE subnet is advertised:

```bash
tailscale status --json | jq -r '.Peer[] | select(.PrimaryRoutes != null) | "\(.HostName): \(.PrimaryRoutes | join(", "))"'
```

Expected:

```text
router: 192.168.2.0/24
```

> `tailscale status` will warn `Some peers are advertising routes but --accept-routes is false` until this is done. Without accepted routes you can reach `wks` but nothing else on 192.168.2.0/24.

### Step 2 — Verify the path to the PCE network

```bash
tailscale ping pce-router
ping -c 3 192.168.2.1
ping -c 3 192.168.2.100
```

The first ICMP reply can take ~500 ms while the Tailscale path is set up; later replies settle around 13 ms. `tailscale ping` reports `via DERP` (relayed) or a direct `IP:port`.

### Step 3 — SSH to the jumphost

```bash
ssh barlow@100.94.163.6
```

or, with MagicDNS enabled:

```bash
ssh barlow@onsite-pce-wks
```

Optional `~/.ssh/config` on your device:

```bash
cat >> ~/.ssh/config <<'EOF'

Host wks onsite-pce-wks
    HostName 100.94.163.6
    User barlow
EOF
ssh wks
```

> Engineers using the `pce` workstation hop (`ssh pce` → `ssh wks`) get the same result. Workstations without `kubectl`/`helm` (e.g. `jmnlsrv1`) should not be used for validation; run everything from `wks`.

### Step 4 — Configure the environment on `wks`

Create the shared environment file once:

```bash
cat > ~/pce.env <<'EOF'
# Denovo PCE — PCE AI/SI Environment
export PCE_CUSTOMER="Denovo PCE"
export PCE_DOMAIN="pce.denovo"
export PCE_SUBNET="192.168.2.0/24"
export PCE_GATEWAY="192.168.2.1"
export PCE_VIP="192.168.2.100"
export PCE_TRAEFIK_IP="192.168.2.99"
export PCE_JUMPHOST="192.168.2.5"
export PCE_NODES="hpec1n1 hpec1n2 hpec1n3 hpec2n1 hpec2n2 hpec2n3"
export PCE_NODE_IPS="192.168.2.111 192.168.2.112 192.168.2.113 192.168.2.115 192.168.2.116 192.168.2.117"
export PCE_CP_IPS="192.168.2.111 192.168.2.113 192.168.2.115"
export PCE_GPU_NODES="hpec1n2 hpec1n3 hpec2n1 hpec2n2 hpec2n3"
export PCE_GPU_NODE_IPS="192.168.2.112 192.168.2.113 192.168.2.115 192.168.2.116 192.168.2.117"
export RANCHER_URL="https://rancher.pce.denovo"
export HARVESTER_URL="https://harvester.pce.denovo"
export RANCHER_CLUSTER_ID="c-m-rlxp8s2v"
export RANCHER_CLUSTER_NAME="harvester-cluster"
export KUBECONFIG="$HOME/.kube/harvester-cluster.yaml"
export EXPECTED_HARVESTER_VERSION="v1.7.2"
export EXPECTED_K8S_VERSION="v1.34.9+rke2r1"
export EXPECTED_GPU_OPERATOR_VERSION="v26.3.3"
EOF
grep -q 'pce.env' ~/.bashrc || echo 'source ~/pce.env' >> ~/.bashrc
source ~/pce.env
```

### Step 5 — Get the Harvester kubeconfig

1. Browse to `https://rancher.pce.denovo` (from `wks`, or from your device with routes accepted and the [hosts entries](#name-resolution) below).
2. **☰ → Cluster Management →** `harvester-cluster` **→ ⋮ → Copy KubeConfig to Clipboard**.
3. On `wks`:

```bash
mkdir -p ~/.kube
cat > ~/.kube/harvester-cluster.yaml    # paste, then Ctrl-D
chmod 600 ~/.kube/harvester-cluster.yaml
kubectl get nodes
```

The kubeconfig routes through Rancher: `https://rancher.pce.denovo/k8s/clusters/c-m-rlxp8s2v`.

### Step 6 — Verify node SSH

```bash
for ip in $PCE_NODE_IPS; do
  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o ConnectTimeout=5 rancher@$ip 'echo "$(hostname): OK"'
done
```

Expected: six `OK` lines (`hpec1n2` reports its OS hostname `harvester-bzhz2`). On failure, follow [`passwdrecovery.md`](passwdrecovery.md).

#### Name resolution

`wks` resolves `*.pce.denovo` from `/etc/hosts`. To use the web UIs from your own device, either add the same entries:

```bash
sudo tee -a /etc/hosts <<'EOF'

# Denovo PCE (requires tailscale --accept-routes)
192.168.2.1   router.pce.denovo glinet.pce.denovo
192.168.2.5   wks.pce.denovo
192.168.2.99  traefik.pce.denovo
192.168.2.100 rancher.pce.denovo harvester.pce.denovo registry.pce.denovo fileserver.pce.denovo keycloak.pce.denovo kasm.pce.denovo apps.pce.denovo notary.pce.denovo auth.pce.denovo server.auth.pce.denovo webserver.pce.denovo builder.pce.denovo unifi.pce.denovo netbox.pce.denovo ollama.pce.denovo webui.pce.denovo
192.168.2.111 hpec1n1.pce.denovo harvester01.pce.denovo
192.168.2.112 hpec1n2.pce.denovo harvester02.pce.denovo
192.168.2.113 hpec1n3.pce.denovo harvester03.pce.denovo
192.168.2.115 hpec2n1.pce.denovo harvester04.pce.denovo
192.168.2.116 hpec2n2.pce.denovo harvester05.pce.denovo
192.168.2.117 hpec2n3.pce.denovo harvester06.pce.denovo
EOF
```

or query the in-cluster CoreDNS exposed on the VIP (`rke2-coredns-external`, UDP/TCP 53), as shown in [4.2](#42-network-connectivity).

---

## 4. Validation Checklist

Run every block from `wks` as `barlow` after `source ~/pce.env`. Each subsection lists the expected result; record deviations in [Known Findings](#5-known-findings-2026-10-21).

| # | Area | Pass criteria |
|---|---|---|
| 4.1 | Environment variables | All `PCE_*` / `RANCHER_*` set; `KUBECONFIG` valid |
| 4.2 | Network | Gateway, VIP, nodes reachable; required ports open |
| 4.3 | Health endpoints | Every ingress host returns 2xx/3xx/401 |
| 4.4 | PostgreSQL | Harbor and Keycloak databases accept connections on 5432 |
| 4.5 | Ingress | ingress-nginx serving on 192.168.2.100; Traefik state known |
| 4.6 | Kubernetes | 6/6 nodes Ready; no failing pods; no pending LoadBalancers |
| 4.7 | Longhorn | All Longhorn nodes Ready/schedulable; all volumes healthy |
| 4.8 | HarvesterOS | v1.7.2 on all nodes; no stuck upgrades |
| 4.9 | Rancher MCM | `/ping` = pong; `harvester-cluster` Active |
| 4.10 | GPU Operator | v26.3.3; ClusterPolicy ready; **every GPU node** runs all operands (`DESIRED = READY`); every GPU allocatable. Currently FAIL: 1 of 5 |

### 4.0 Quick Health Check

[`pce-healthcheck.sh`](pce-healthcheck.sh) checks all six nodes and the GPU Operator in one pass. Run it first; it exits with the number of failed checks (0 = healthy).

```bash
bash pce-healthcheck.sh | tee ~/pce-health-$(date +%Y%m%d-%H%M).txt
echo "failed checks: ${PIPESTATUS[0]}"
```

| # | Section | PASS when |
|---|---|---|
| 1 | Network | All 6 node IPs answer ping and SSH (port 22) |
| 2 | Kubernetes nodes | 6 nodes, `Ready`, not cordoned, `v1.34.9+rke2r1` |
| 3 | Node pressure | No Memory/Disk/PID/Network pressure |
| 4 | Maintenance mode | `off` on all nodes (WARN, not FAIL, during planned work) |
| 5 | Longhorn | 6 storage nodes ready and schedulable; attached volumes `healthy` |
| 6 | Load | Informational (`kubectl top nodes`) |
| 7 | Pods | Informational; lists nodes with non-running pods |
| 8 | GPU Operator | Chart `gpu-operator-v26.3.3`, ClusterPolicy `ready`, controller `Running` |
| 9 | GPU nodes | On each of `hpec1n2`, `hpec1n3`, `hpec2n1`, `hpec2n2`, `hpec2n3`: GFD, device plugin, DCGM exporter and validator ready, and `nvidia.com/gpu` allocatable ≥ 1 |
| 10 | GPU DaemonSets | Every `nvidia-*` DaemonSet has `ready = desired` |

**Expected today (2026-10-21):** sections 8–10 FAIL for `hpec1n2`, `hpec1n3`, `hpec2n2` and `hpec2n3` (Known Findings #8–#10), and section 7 WARNs for those nodes' GPU pods and the pending `metal3` load balancer. Everything else should PASS. After [`gpu-node-setup.md`](gpu-node-setup.md) is complete, the script should report `HEALTHY`.

### 4.1 Environment Variables

```bash
source ~/pce.env
for v in PCE_CUSTOMER PCE_DOMAIN PCE_SUBNET PCE_GATEWAY PCE_VIP PCE_NODES PCE_NODE_IPS \
         RANCHER_URL HARVESTER_URL RANCHER_CLUSTER_ID KUBECONFIG EXPECTED_HARVESTER_VERSION \
         EXPECTED_K8S_VERSION EXPECTED_GPU_OPERATOR_VERSION; do
  printf '%-32s %s\n' "$v" "${!v:-<<UNSET>>}"
done

[ -r "$KUBECONFIG" ] && echo "kubeconfig: readable" || echo "kubeconfig: MISSING"
stat -c '%a %U %n' "$KUBECONFIG"                       # expect: 600 barlow
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
whoami                                                  # expect: barlow
```

Expected server: `https://rancher.pce.denovo/k8s/clusters/c-m-rlxp8s2v`.

Check that `kubectl` matches the cluster:

```bash
kubectl version -o json | jq -r '"client: \(.clientVersion.gitVersion)  server: \(.serverVersion.gitVersion)"'
```

Expected: `client: v1.34.9  server: v1.34.9+rke2r1`.

### 4.2 Network Connectivity

Tailscale and routing:

```bash
tailscale status | grep -E "onsite-pce-wks|pce-router"
ping -c 2 -W 2 $PCE_GATEWAY
ping -c 2 -W 2 $PCE_VIP
```

Port reachability (no `nc` required):

```bash
check_port() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo "OPEN    $1:$2 ($3)" || echo "CLOSED  $1:$2 ($3)"; }

check_port 192.168.2.1   22   gateway-ssh
check_port 192.168.2.1   443  gateway-ui
check_port 192.168.2.100 80   ingress-http
check_port 192.168.2.100 443  ingress-https
check_port 192.168.2.100 6443 kube-apiserver
check_port 192.168.2.100 9345 rke2-supervisor
check_port 192.168.2.100 53   coredns-external
check_port 192.168.2.100 88   kerberos
check_port 192.168.2.100 389  ldap
check_port 192.168.2.100 8080 webserver-port
check_port 192.168.2.99  443  traefik

for ip in $PCE_NODE_IPS; do check_port $ip 22 node-ssh; done
for ip in $PCE_CP_IPS;   do check_port $ip 6443 apiserver; check_port $ip 9345 supervisor; done
for ip in 192.168.2.11 192.168.2.12 192.168.2.13; do check_port $ip 443 bmc; done
```

Expected: all `OPEN` except `192.168.2.99:443` (see [Known Findings](#5-known-findings-2026-10-21)). Workers `.112/.116/.117` do not expose 6443/9345, which is normal.

DNS:

```bash
getent hosts rancher.pce.denovo harvester.pce.denovo registry.pce.denovo
dig +short @192.168.2.100 kubernetes.default.svc.cluster.local
dig +short @192.168.2.100 rancher.pce.denovo
```

`getent` must return 192.168.2.100 for each host. The CoreDNS query confirms the external DNS service answers on the VIP.

Latency and path:

```bash
tailscale ping -c 3 pce-router
```

### 4.3 Service Health Endpoints

```bash
for url in \
  "https://rancher.pce.denovo/ping" \
  "https://rancher.pce.denovo/rancherversion" \
  "https://harvester.pce.denovo/ping" \
  "https://harvester.pce.denovo/dashboard/" \
  "https://registry.pce.denovo/api/v2.0/health" \
  "https://keycloak.pce.denovo/realms/master" \
  "https://fileserver.pce.denovo/" \
  "https://webserver.pce.denovo/" \
  "https://builder.pce.denovo/" \
  "http://server.auth.pce.denovo/" \
  "http://192.168.2.100:8080/" \
  "https://ollama.pce.denovo/" \
  "https://webui.pce.denovo/"; do
  code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$url")
  printf '%-50s %s\n' "$url" "$code"
done
```

| Code | Meaning |
|---|---|
| 200 / 30x / 401 / 403 | Service up (auth may be required) |
| 404 | Ingress host has no backend: check `kubectl get ingress -A` |
| 502 / 503 / 504 | Backend pods down |
| 000 | Not reachable: check routes, hosts file, VIP |

Content checks:

```bash
curl -sk https://rancher.pce.denovo/ping; echo              # expect: pong
curl -sk https://rancher.pce.denovo/rancherversion | jq .    # Rancher MCM version
curl -sk https://registry.pce.denovo/api/v2.0/health | jq -r '.status, (.components[] | "\(.name): \(.status)")'
```

Harbor should report `healthy` for every component.

TLS certificates (expiry and issuer):

```bash
for h in rancher harvester registry keycloak fileserver webserver builder; do
  echo "== $h.pce.denovo"
  echo | openssl s_client -connect 192.168.2.100:443 -servername $h.pce.denovo 2>/dev/null \
    | openssl x509 -noout -subject -issuer -enddate
done
kubectl get certificates -A
```

All cert-manager certificates should show `READY=True`.

### 4.4 PostgreSQL (5432)

Both databases are **ClusterIP only**; port 5432 is intentionally not exposed on 192.168.2.100.

| Service | Namespace | Type |
|---|---|---|
| `harbor-database` | `harbor-system` | ClusterIP 10.53.222.182:5432 |
| `postgresql-headless` | `keycloak-system` | Headless :5432 |

Confirm the external VIP does **not** expose Postgres:

```bash
timeout 3 bash -c "</dev/tcp/192.168.2.100/5432" 2>/dev/null && echo "WARNING: 5432 exposed on VIP" || echo "OK: 5432 not exposed externally"
```

Check readiness inside each database pod:

```bash
for svc in harbor-system/harbor-database keycloak-system/postgresql-headless; do
  ns=${svc%/*}; name=${svc#*/}
  pod=$(kubectl -n $ns get endpoints $name -o jsonpath='{.subsets[0].addresses[0].targetRef.name}')
  echo "== $ns/$name -> pod $pod"
  kubectl -n $ns exec $pod -- pg_isready -h 127.0.0.1 -p 5432
done
```

Expected: `127.0.0.1:5432 - accepting connections` for both.

TCP check of port 5432 through a port-forward from `wks`:

```bash
kubectl -n harbor-system port-forward svc/harbor-database 15432:5432 >/dev/null 2>&1 &
PF=$!; sleep 3
timeout 3 bash -c "</dev/tcp/127.0.0.1/15432" && echo "harbor-database 5432: OPEN" || echo "harbor-database 5432: CLOSED"
kill $PF
```

Check that the Postgres PVCs are bound on Longhorn:

```bash
kubectl get pvc -n harbor-system; kubectl get pvc -n keycloak-system
```

### 4.5 Ingress: NGINX and Traefik

Both RKE2 ingress controllers are installed. **ingress-nginx** serves 192.168.2.100 through the `ingress-expose` LoadBalancer.

Ingress classes and the default:

```bash
kubectl get ingressclass
kubectl get ingressclass -o json | jq -r '.items[] | "\(.metadata.name)  default=\(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "false")  controller=\(.spec.controller)"'
```

NGINX:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=rke2-ingress-nginx -o wide
kubectl -n kube-system get ds,deploy -l app.kubernetes.io/name=rke2-ingress-nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl -n kube-system get svc ingress-expose
curl -sk -o /dev/null -w 'nginx default backend: %{http_code}\n' -H "Host: does-not-exist.pce.denovo" https://192.168.2.100/
```

Expected: one controller pod per node, all `Running`. The image tag is `v1.15.1`. `ingress-expose` has `EXTERNAL-IP 192.168.2.100` on ports 80/443, and an unknown host returns `404`.

Traefik:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=rke2-traefik -o wide
kubectl -n kube-system get svc -l app.kubernetes.io/name=rke2-traefik
kubectl -n kube-system get deploy,ds -l app.kubernetes.io/name=rke2-traefik \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl get ingressroute -A 2>/dev/null
ping -c 2 -W 2 192.168.2.99
```

Expected: Traefik pods `Running` with image `v3.7.1`. **As of 2026-10-21, no Traefik LoadBalancer service exists and 192.168.2.99 does not respond**, so `traefik.pce.denovo` is not served. Confirm whether Traefik is meant to be exposed before treating this as a fault.

Ingress inventory:

```bash
kubectl get ingress -A
```

Expected hosts: `server.auth`, `builder`, `registry`, `fileserver`, `keycloak`, `rancher`, `webserver` (all `.pce.denovo`), plus the `rancher-expose` wildcard.

### 4.6 Kubernetes Cluster Health

```bash
kubectl get nodes -o wide
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name)  ready=\(.status.conditions[] | select(.type=="Ready") | .status)  kubelet=\(.status.nodeInfo.kubeletVersion)  os=\(.status.nodeInfo.osImage)"'
```

Expected: 6 nodes, `ready=True`, `kubelet=v1.34.9+rke2r1`, `os=Harvester v1.7.2`.

Node pressure conditions:

```bash
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n | .status.conditions[] | select(.type!="Ready" and .status=="True") | "\($n): \(.type)"'
```

Expected: no output.

Unhealthy pods:

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get pods -A -o json | jq -r '.items[] | select([.status.containerStatuses[]?.restartCount] | add > 10) | "\(.metadata.namespace)/\(.metadata.name) restarts=\([.status.containerStatuses[]?.restartCount] | add)"'
```

LoadBalancer services:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Expected: `ingress-expose`, `rke2-coredns-external`, `auth-external`, `ntp` and `webserver-port` on 192.168.2.100. `metal3-metal3-ironic` is currently `<pending>` (known finding).

Core components:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get pods -l k8s-app=canal
kubectl -n kube-system get pods -l app=rke2-multus
kubectl -n cert-manager get pods
kubectl -n cattle-fleet-system get pods
kubectl -n cattle-monitoring-system get pods
kubectl top nodes
```

Helm release status:

```bash
helm list -A --failed --pending
helm list -A | awk 'NR==1 || $8!="deployed"'
```

Expected: no failed or pending releases.

### 4.7 Longhorn Storage

Version:

```bash
kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Storage classes:

```bash
kubectl get sc
```

Expected: `harvester-longhorn (default)`, `k8s-longhorn`, `k8s-xfs-longhorn`, `longhorn`, `longhorn-static` and `vmstate-persistence`, all `driver.longhorn.io`.

Longhorn nodes and disks:

```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | "\(.metadata.name)  ready=\(.status.conditions[] | select(.type=="Ready") | .status)  schedulable=\(.status.conditions[] | select(.type=="Schedulable") | .status)"'
```

Expected: 6 nodes, `ready=True schedulable=True`.

Volume health:

```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '.items[] | select(.status.robustness!="healthy") | "\(.metadata.name)  state=\(.status.state)  robustness=\(.status.robustness)"'
```

Expected: the second command prints nothing. A `degraded` volume is rebuilding or missing a replica; `faulted` needs immediate escalation.

Key settings:

```bash
for s in default-replica-count storage-over-provisioning-percentage storage-minimal-available-percentage replica-soft-anti-affinity; do
  printf '%-40s %s\n' "$s" "$(kubectl -n longhorn-system get settings.longhorn.io $s -o jsonpath='{.value}')"
done
```

Longhorn pods:

```bash
kubectl -n longhorn-system get pods --field-selector=status.phase!=Running
```

### 4.8 HarvesterOS

Version and settings:

```bash
kubectl get settings.harvesterhci.io server-version -o jsonpath='{.value}{"\n"}'
kubectl get settings.harvesterhci.io -o custom-columns=NAME:.metadata.name,VALUE:.value | grep -E "server-version|cluster-registration-url|ntp-servers|additional-ca|containerd-registry|http-proxy"
```

Expected: `v1.7.2`.

OS on each node:

```bash
for ip in $PCE_NODE_IPS; do
  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o ConnectTimeout=5 rancher@$ip \
    'printf "%-18s %s  kernel=%s  uptime=%s\n" "$(hostname)" "$(. /etc/os-release; echo $PRETTY_NAME)" "$(uname -r)" "$(uptime -p)"'
done
```

Harvester system pods:

```bash
kubectl -n harvester-system get pods --field-selector=status.phase!=Running
kubectl -n harvester-system get deploy harvester -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Upgrades, VMs, networks, PCI devices:

```bash
kubectl -n harvester-system get upgrades.harvesterhci.io
kubectl get virtualmachines.kubevirt.io -A
kubectl get vmi -A
kubectl get clusternetworks.network.harvesterhci.io
kubectl get network-attachment-definitions -A
kubectl get pcidevices.devices.harvesterhci.io | grep -i nvidia
kubectl get cloudinits.node.harvesterhci.io
```

Expected: no upgrade in progress, all VMIs `Running`, and `pce-engineer-ssh-keys` present in `cloudinits`.

### 4.9 Rancher MCM

Rancher MCM runs inside the **`rancher-vcluster`** vcluster on Harvester and is published at `rancher.pce.denovo`. Harvester's own embedded Rancher (chart 2.13.3, `cattle-system`) serves `harvester.pce.denovo`.

Endpoint health:

```bash
curl -sk https://rancher.pce.denovo/ping; echo
curl -sk https://rancher.pce.denovo/rancherversion | jq .
curl -sk https://rancher.pce.denovo/healthz; echo
```

vcluster hosting Rancher MCM:

```bash
kubectl -n rancher-vcluster get pods,svc,pvc
kubectl -n rancher-vcluster get ingress
helm -n rancher-vcluster list
```

Expected: vcluster pods `Running` and the ingress host `rancher.pce.denovo`.

Downstream clusters as seen by Rancher (uses the token from your kubeconfig):

```bash
TOKEN=$(awk -F'"' '/token:/ {print $2}' "$KUBECONFIG")
curl -sk -H "Authorization: Bearer $TOKEN" "$RANCHER_URL/v3/clusters" \
  | jq -r '.data[] | "\(.name)  id=\(.id)  state=\(.state)  k8s=\(.version.gitVersion // "n/a")"'
```

Expected: `harvester-cluster  id=c-m-rlxp8s2v  state=active  k8s=v1.34.9+rke2r1`.

Fleet and agents:

```bash
kubectl -n cattle-fleet-system get pods
kubectl -n cattle-system get pods
```

### 4.10 NVIDIA GPU Operator

Expected: chart **v26.3.3** in `gpu-operator`, running on all **five GPU nodes**.

#### GPU inventory (authoritative, from Harvester PCI devices, 2026-10-21)

| Node | GPU | PCI address | Host driver bound | Operator status |
|---|---|---|---|---|
| `hpec1n1` | none | — | — | Not a GPU node |
| `hpec1n2` | NVIDIA A2 (GA107GL) | 0000:4b:00.0 | **none** | Stuck: no driver |
| `hpec1n3` | NVIDIA A40 (GA102GL) | 0000:4b:00.0 | `nvidia` | Stuck: driver bound, validation failing |
| `hpec2n1` | NVIDIA A2 (GA107GL) | 0000:4b:00.0 | `nvidia` | **Healthy (reference node)** |
| `hpec2n2` | NVIDIA A2 (GA107GL) | 0000:4b:00.0 | **none** | Stuck: no driver |
| `hpec2n3` | NVIDIA A100 PCIe 40GB (GA100) | 0000:4b:00.0 | **none** | Stuck: no driver |

Re-check the inventory at any time. This works even when no driver is loaded:

```bash
kubectl get pcidevices.devices.harvesterhci.io \
  -o custom-columns=NODE:.status.nodeName,DEVICE:.status.description,ADDRESS:.status.address,DRIVER:.status.kernelDriverInUse \
  | grep -iE "NODE|nvidia"
```

| `DRIVER` value | Meaning |
|---|---|
| `nvidia` | Host driver bound; usable by the GPU Operator |
| `<none>` | No driver loaded; operands will stay in `Init` |
| `vfio-pci` | Reserved for Harvester VM passthrough; not usable by containers |

Operator version:

```bash
helm -n gpu-operator list
helm -n gpu-operator list -o json | jq -r '.[] | select(.name=="gpu-operator") | .chart'
```

Expected: `gpu-operator-v26.3.3`.

ClusterPolicy state:

```bash
kubectl get clusterpolicies.nvidia.com
kubectl get clusterpolicies.nvidia.com -o jsonpath='{.items[0].status.state}{"\n"}'
```

Expected: `ready`.

Which nodes run the GPU Operator. The operator controller runs on one node, the GPU operands (driver, toolkit, device plugin, DCGM, GFD, validators) only on nodes labeled `nvidia.com/gpu.present=true`, and Node Feature Discovery workers on every node:

```bash
echo "== operator controller";  kubectl -n gpu-operator get pods -l app=gpu-operator -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
echo "== GPU-enabled nodes";    kubectl get nodes -l nvidia.com/gpu.present=true -L nvidia.com/gpu.product,nvidia.com/gpu.deploy.driver
echo "== operands per node"
kubectl -n gpu-operator get pods -o json | jq -r '.items[] | "\(.spec.nodeName)\t\(.metadata.labels.app // .metadata.name)"' | sort -u | \
  awk -F'\t' '{a[$1]=a[$1] ? a[$1]", "$2 : $2} END {for (n in a) print n": "a[n]}' | sort
echo "== daemonset coverage";   kubectl -n gpu-operator get ds
```

#### GPU Operator placement baseline (captured 2026-10-21)

The operator runs **without** a driver or container-toolkit DaemonSet: neither `nvidia-driver-daemonset` nor `nvidia-container-toolkit-daemonset` exists. The NVIDIA driver must therefore be installed on the host. Operands are scheduled on **5 of 6 nodes**, but only **`hpec2n1`** is fully working.

| Node | GPU (label) | Controller / NFD | gpu-feature-discovery | device-plugin | dcgm-exporter | operator-validator | cuda-validator | State |
|---|---|---|---|---|---|---|---|---|
| `hpec1n1` | — | NFD worker | not scheduled | not scheduled | not scheduled | not scheduled | — | **Excluded** (no `gpu.deploy.*` labels) |
| `hpec1n2` | NVIDIA A2 ×1 (no driver bound) | NFD worker | Init:0/1 | Init:0/1 | Init:0/1 | Init:0/4 | — | **Stuck**: no host driver bound to GPU |
| `hpec1n3` | NVIDIA A40 ×1 (`nvidia` driver bound) | NFD worker | Init:0/1 | Init:0/1 | Init:0/1 | Init:0/4 | — | **Stuck**: driver bound, validation not passing |
| `hpec2n1` | NVIDIA-A2 ×1 | NFD worker | Running | Running | Running | Running | Completed | **Healthy** |
| `hpec2n2` | NVIDIA A2 ×1 (no driver bound) | **gpu-operator controller**, NFD worker | Init:0/1 | Init:0/1 | Init:0/1 | Init:0/4 | — | **Stuck**: no host driver bound to GPU |
| `hpec2n3` | NVIDIA A100 PCIe 40GB ×1 (no driver bound) | **NFD master + gc**, NFD worker | Init:0/1 | Init:0/1 | Init:0/1 | Init:0/4 | — | **Stuck**: no host driver bound to GPU |

DaemonSet baseline:

| DaemonSet | Desired | Ready | Node selector |
|---|---|---|---|
| `gpu-operator-node-feature-discovery-worker` | 6 | 6 | none |
| `gpu-feature-discovery` | 5 | 1 | `nvidia.com/gpu.deploy.gpu-feature-discovery=true` |
| `nvidia-device-plugin-daemonset` | 5 | 1 | `nvidia.com/gpu.deploy.device-plugin=true` |
| `nvidia-dcgm-exporter` | 5 | 1 | `nvidia.com/gpu.deploy.dcgm-exporter=true` |
| `nvidia-operator-validator` | 5 | 1 | `nvidia.com/gpu.deploy.operator-validator=true` |
| `nvidia-device-plugin-mps-control-daemon` | 0 | 0 | MPS not in use |
| `nvidia-mig-manager` | 0 | 0 | MIG not in use |

> **Requirement: every node with an NVIDIA GPU must run the full GPU Operator stack.** On each node where NFD detects an NVIDIA PCI device (`feature.node.kubernetes.io/pci-10de.present=true`), these must be healthy: `gpu-feature-discovery`, `nvidia-device-plugin-daemonset`, `nvidia-dcgm-exporter` and `nvidia-operator-validator` (`Running`), plus `nvidia-cuda-validator` (`Completed`). The node must also advertise `nvidia.com/gpu` allocatable ≥ 1. Never set `nvidia.com/gpu.deploy.operands=false` on a GPU node.

Five nodes have GPUs (confirmed through Harvester PCI devices; see the [GPU inventory](#gpu-inventory-authoritative-from-harvester-pci-devices-2026-10-21)). **Target: `DESIRED = READY = 5` on every `nvidia-*` DaemonSet.** See [Known Findings](#5-known-findings-2026-10-21) #8–#10.

#### Requirement check: every GPU node runs the operator

This exits non-zero if any GPU node is missing a healthy operand. Use it as the pass/fail gate for section 4.10:

```bash
FAIL=0
GPU_NODES=$(kubectl get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[*].metadata.name}')
echo "Nodes with NVIDIA PCI hardware: $GPU_NODES"
for n in $GPU_NODES; do
  for app in gpu-feature-discovery nvidia-device-plugin-daemonset nvidia-dcgm-exporter nvidia-operator-validator; do
    ready=$(kubectl -n gpu-operator get pods -l app=$app --field-selector spec.nodeName=$n \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
    [ "$ready" = "true" ] && s=OK || { s=FAIL; FAIL=1; }
    printf '%-10s %-34s %s\n' "$n" "$app" "$s"
  done
  alloc=$(kubectl get node $n -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  [ "${alloc:-0}" -ge 1 ] && s=OK || { s=FAIL; FAIL=1; }
  printf '%-10s %-34s %s (%s)\n' "$n" "nvidia.com/gpu allocatable" "$s" "${alloc:-0}"
done
[ $FAIL -eq 0 ] && echo "PASS: all GPU nodes run the GPU Operator" || { echo "FAIL: see rows above"; false; }
```

#### Diagnose stuck operand pods

Find out why a node was selected and why its init containers are waiting:

```bash
# Which nodes carry the deploy labels, and what NVIDIA PCI hardware NFD found
kubectl get nodes -L nvidia.com/gpu.present,nvidia.com/gpu.deploy.operands,nvidia.com/gpu.deploy.device-plugin,feature.node.kubernetes.io/pci-10de.present

# Init container logs on the stuck A40 node (validator waits for the driver)
POD=$(kubectl -n gpu-operator get pods -l app=nvidia-operator-validator --field-selector spec.nodeName=hpec1n3 -o jsonpath='{.items[0].metadata.name}')
kubectl -n gpu-operator describe pod $POD | sed -n '/Init Containers/,/Containers:/p'
kubectl -n gpu-operator logs $POD -c driver-validation --tail=30

# ClusterPolicy: driver/toolkit management is disabled when these are false
kubectl get clusterpolicies.nvidia.com -o jsonpath='driver.enabled={.items[0].spec.driver.enabled}  toolkit.enabled={.items[0].spec.toolkit.enabled}{"\n"}'
```

Check the hardware and driver on each scheduled node:

```bash
for ip in 192.168.2.112 192.168.2.113 192.168.2.115 192.168.2.116 192.168.2.117; do
  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o ConnectTimeout=5 rancher@$ip '
    echo "== $(hostname)"
    echo "-- NVIDIA PCI devices and bound kernel driver:"
    lspci -nnk -d 10de: | grep -E "^[0-9a-f]|Kernel driver in use" || echo "   none"
    echo "-- nvidia kernel module:"; lsmod | grep -q "^nvidia " && echo "   loaded" || echo "   NOT loaded"
    command -v nvidia-smi >/dev/null && nvidia-smi -L || echo "   nvidia-smi not found"'
done
```

Check for GPUs claimed by Harvester for VM passthrough (bound to `vfio-pci`, so containers can't use them):

```bash
kubectl get pcidevices.devices.harvesterhci.io -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,DESC:.status.description,DRIVER:.status.kernelDriverInUse | grep -i nvidia
kubectl get pcideviceclaims.devices.harvesterhci.io
```

How to read the results:

`hpec2n1` is the working reference. Every other GPU node must end up matching its driver, module, runtime and validation state.

Compare each stuck node against `hpec2n1`:

```bash
for n in $PCE_GPU_NODES; do
  echo "==================== $n"
  kubectl debug node/$n -q -i --profile=sysadmin \
    --image=registry.suse.com/bci/bci-base -- chroot /host sh -c '
      echo "-- kernel driver:";  head -1 /proc/driver/nvidia/version 2>/dev/null || echo "   NOT loaded"
      echo "-- nvidia-smi:";     nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1
      echo "-- /run/nvidia:";    ls -la /run/nvidia/ 2>&1
      echo "-- driver root:";    ls /run/nvidia/driver 2>&1 | head -5
      echo "-- validations:";    ls -la /run/nvidia/validations 2>&1
      echo "-- containerd nvidia runtime:"; grep -l nvidia /var/lib/rancher/rke2/agent/etc/containerd/config.toml* 2>/dev/null || echo "   not configured"'
done
kubectl get addons.harvesterhci.io -A | grep -i nvidia
```

How to read the results:

| Result on a stuck node | Meaning | Fix |
|---|---|---|
| `Kernel driver in use: vfio-pci` | GPU is bound for Harvester VM passthrough, so containers can't use it | Release the passthrough claim (`kubectl get pcideviceclaims.devices.harvesterhci.io`, then disable passthrough for that device in the Harvester UI) so the `nvidia` driver can bind |
| No driver bound, `nvidia` module NOT loaded | Host driver missing | Install it the same way it was installed on `hpec2n1` (check whether a Harvester `nvidia-driver-toolkit` addon is enabled), or enable `driver.enabled` in the ClusterPolicy |
| `nvidia-smi` works but `/run/nvidia/validations` is empty | Validator can't reach the driver or runtime | Compare the containerd `nvidia` runtime config with `hpec2n1`; check `toolkit.enabled` |
| Differs from `hpec2n1` in any row | Configuration drift | Bring the node to match `hpec2n1` |

After fixing a node, restart its stuck operand pods and re-run the requirement check:

```bash
NODE=hpec1n3
kubectl -n gpu-operator delete pod --field-selector spec.nodeName=$NODE -l 'app in (gpu-feature-discovery,nvidia-device-plugin-daemonset,nvidia-dcgm-exporter,nvidia-operator-validator)'
kubectl -n gpu-operator get pods -o wide --field-selector spec.nodeName=$NODE -w
```

> `nvidia.com/gpu.deploy.operands=false` is only for a node that is confirmed to have **no** NVIDIA GPU. Applying it to a GPU node violates the requirement above.

Operator pods:

```bash
kubectl -n gpu-operator get pods -o wide
kubectl -n gpu-operator get pods --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Expected (target): `gpu-operator` controller, NFD master, gc and 6 NFD workers `Running`. `gpu-feature-discovery`, `nvidia-device-plugin-daemonset`, `nvidia-dcgm-exporter` and `nvidia-operator-validator` `Running`, and `nvidia-cuda-validator` `Completed`, on every GPU node. There are no driver or toolkit pods; this cluster uses the host driver. Current state: only `hpec2n1` meets this (see the placement baseline above).

GPU inventory and allocatable:

```bash
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | "\(.metadata.name)  allocatable=\(.status.allocatable["nvidia.com/gpu"])  capacity=\(.status.capacity["nvidia.com/gpu"])"'
```

Target:

```text
hpec1n2  allocatable=1  capacity=1     (NVIDIA A2)
hpec1n3  allocatable=1  capacity=1     (NVIDIA A40)
hpec2n1  allocatable=1  capacity=1     (NVIDIA A2)
hpec2n2  allocatable=1  capacity=1     (NVIDIA A2)
hpec2n3  allocatable=1  capacity=1     (NVIDIA A100 PCIe 40GB)
```

As of 2026-10-21 only `hpec2n1` appears here, because the device plugin is stuck in `Init` on every other GPU node.

Driver and CUDA versions (from GPU Feature Discovery labels):

```bash
for n in $PCE_GPU_NODES; do
  echo "== $n"
  kubectl get node $n -o json | jq -r '.metadata.labels | to_entries[] | select(.key | test("nvidia.com/(cuda|gpu\\.(product|family|memory)|mig|gfd)")) | "  \(.key)=\(.value)"'
done
```

`nvidia-smi` on each GPU node. The driver is on the host, not in a DaemonSet:

```bash
for ip in $PCE_GPU_NODE_IPS; do
  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o ConnectTimeout=5 rancher@$ip \
    'echo "== $(hostname)"; nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu,utilization.gpu --format=csv || echo "nvidia-smi failed"'
done
```

Alternatively, run it from the healthy device-plugin pod on `hpec2n1`:

```bash
POD=$(kubectl -n gpu-operator get pods -l app=nvidia-device-plugin-daemonset --field-selector spec.nodeName=hpec2n1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n gpu-operator exec $POD -- nvidia-smi
```

Validator results:

```bash
kubectl -n gpu-operator logs -l app=nvidia-cuda-validator --tail=20 2>/dev/null
kubectl -n gpu-operator get pods -l app=nvidia-operator-validator
```

Optional functional test. This schedules a CUDA job on the A40. The image must be reachable; in this air-gapped environment, mirror it into `registry.pce.denovo` first and adjust `image:`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pce-cuda-vectoradd
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-A40
  containers:
  - name: vectoradd
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/pce-cuda-vectoradd --timeout=180s
kubectl logs pce-cuda-vectoradd
kubectl delete pod pce-cuda-vectoradd
```

Expected log ends with `Test PASSED`.

---

## 5. Known Findings (2026-10-21)

| # | Finding | Impact | Action |
|---|---|---|---|
| 1 | `traefik.pce.denovo` (192.168.2.99) does not respond; no Traefik LoadBalancer service exists | Anything expecting Traefik on .99 is unreachable | Confirm intended design; create LB service or remove hosts entry |
| 2 | `metal3-metal3-ironic` LoadBalancer is `<pending>` | Metal3/Ironic bare-metal provisioning endpoints unreachable | Check LB IP pool / kube-vip config |
| 3 | `ollama.pce.denovo` and `webui.pce.denovo` resolve to the VIP but have no Ingress | Requests return 404 | Deploy workloads or remove hosts entries |
| 4 | Chassis 2 BMCs are on `192.168.3.0/24`, which is not advertised on the tailnet | BMCs `192.168.3.11–13` reachable only from `wks` | Advertise the route on `pce-router` if remote BMC access is needed |
| 5 | `hpec1n2` OS hostname is `harvester-bzhz2` | Cosmetic; confusing in shells and logs | Rename at next maintenance window |
| 6 | Node `rancher` password was unknown; SSH keys missing | No host access | Resolved via [`passwdrecovery.md`](passwdrecovery.md) |
| 7 | `pam_faillock: Unknown option: onerr` in sshd logs | Log noise only | None |
| 8 | **`hpec1n3` (A40)**: `nvidia` driver is bound, but operands are stuck `Init` | A40 not allocatable; **violates the "every GPU node runs the operator" requirement** | Driver is present, so check the `driver-validation` init logs and the containerd `nvidia` runtime against `hpec2n1` ([Diagnose stuck operand pods](#diagnose-stuck-operand-pods)) |
| 9 | **`hpec1n2` (A2), `hpec2n2` (A2), `hpec2n3` (A100 40GB)**: no host driver, toolkit or setup service | 3 GPUs unusable; `DESIRED 5 / READY 1`; **violates the requirement** | Follow [`gpu-node-setup.md`](gpu-node-setup.md) on one node at a time, starting with `hpec1n2` |
| 10 | ClusterPolicy uses `driver.enabled=false`, `rootFS=/`; GPU nodes depend on a manual host install. Reference build on `hpec2n1`: NVIDIA `.run` installer **595.71.05** (open kernel module, installed 2026-08-19, log `/var/log/nvidia-installer.log`), **nvidia-container-toolkit 1.20.0** RPMs (`nvidia-container-toolkit`, `-base`, `libnvidia-container1`, `libnvidia-container-tools`), and RKE2 containerd runtime `nvidia` → `/usr/local/bin/nvidia-container-runtime`. Harvester addon `nvidia-driver-toolkit` exists but is **disabled** | Nodes without this exact stack never get the `nvidia` runtime (`hpec1n2` failed sandbox creation 338,878 times over 51 days) | Replicate the reference build on `hpec1n2`, `hpec2n2`, `hpec2n3`, restart RKE2 on each, then delete their operand pods. Confirm the install persists across a Harvester reboot/upgrade |

---

## 6. Troubleshooting / Escalation

### Connection

| Symptom | Likely cause | Fix |
|---|---|---|
| `onsite-pce-wks` not in `tailscale status` | Share not accepted, or device not approved | Ask barlow to approve; accept the share in the Tailscale admin console |
| `Some peers are advertising routes but --accept-routes is false` | Routes not accepted | `sudo tailscale set --accept-routes` |
| Can SSH to `wks` but can't ping 192.168.2.x | Routes not accepted, or `pce-router` offline | Accept routes; check that `tailscale status` shows `pce-router` online |
| High latency (>100 ms sustained) | Traffic relayed through DERP | `tailscale ping pce-router`; check UDP 41641 egress on your network |
| `*.pce.denovo` doesn't resolve | No hosts entries on your device | Add the [hosts block](#name-resolution) or work from `wks` |
| `kubectl: command not found` | Not on `wks`, or kubectl not installed | `ssh wks`; see [Prerequisites](#jumphost-tools-wks) |
| `awk: cannot open '/root/.kube/...'` | Running as root | `exit` back to barlow |

### Kubernetes and Rancher

| Symptom | Likely cause | Fix |
|---|---|---|
| `Unauthorized` / `401` from kubectl | Rancher token expired or deleted | Download a new kubeconfig ([Step 5](#step-5--get-the-harvester-kubeconfig)) |
| kubectl hangs | Rancher MCM (`rancher-vcluster`) down | Check `https://rancher.pce.denovo/ping`; use the BMC console or node SSH and `/etc/rancher/rke2/rke2.yaml` on a control-plane node |
| `get nodes` shows non-`hpec*` nodes | Wrong cluster's kubeconfig | Choose `harvester-cluster` in Rancher |
| `kubectl debug` → `ImagePullBackOff` | Node can't pull `registry.suse.com/bci/bci-base` | Use a mirror in `registry.pce.denovo` |
| Ingress host returns 404 | No Ingress for that host | `kubectl get ingress -A` |
| Ingress host returns 502/503 | Backend pods down | `kubectl -n <ns> get pods`; check events |

Emergency direct API access, bypassing Rancher (from a control-plane node):

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa rancher@192.168.2.111
sudo -i
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes
```

### Node access

| Symptom | Fix |
|---|---|
| `Too many authentication failures` | `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa rancher@<node-ip>` |
| Key rejected / password unknown | [`passwdrecovery.md`](passwdrecovery.md) |
| Password stops working after retries | `pam_faillock` lockout; see [`passwdrecovery.md` Step 6](passwdrecovery.md#step-6--install-your-ssh-key-on-all-nodes) |
| `sudo: a password is required` over SSH | The `rancher` sudo password is unknown | Run root-level checks with `kubectl debug node/<node> ... -- chroot /host`, or set a password ([`passwdrecovery.md` Step 9](passwdrecovery.md#step-9--reset-the-rancher-password-optional)) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Node reinstalled/regenerated host keys, **or** an interception attempt | Verify the fingerprint out-of-band first: `kubectl debug node/<node> -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host sh -c 'for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf $k; done'`. Only if it matches, run `ssh-keygen -R <ip>` and reconnect |
| GPU operand pods `Init` with no pod IP; event `no runtime for "nvidia" is configured` | Node has no NVIDIA driver/container toolkit, so RKE2 never registered the `nvidia` containerd runtime | Install driver and toolkit on the host, then restart RKE2 on that node so it detects the runtime |
| Long USG banner on every SSH connection | Required DoD login banner on the nodes | Expected; do not remove. Use `ssh -q` to suppress it in loops |

### Storage and GPU

| Symptom | Likely cause | Fix |
|---|---|---|
| Longhorn volume `degraded` | Replica rebuilding or node down | `kubectl -n longhorn-system get replicas.longhorn.io \| grep <volume>`; wait for the rebuild or check the node |
| Longhorn volume `faulted` | All replicas lost | **Escalate immediately**; do not delete the volume |
| `nvidia.com/gpu` allocatable is 0 | Device plugin or driver failure | `kubectl -n gpu-operator get pods -o wide`; check driver pod logs |
| ClusterPolicy not `ready` | Operand failing | `kubectl describe clusterpolicies.nvidia.com`; check validator logs |
| GPU missing after reboot | PCI passthrough claimed by Harvester | `kubectl get pcidevices.devices.harvesterhci.io \| grep -i nvidia`; check `pcideviceclaims` |

### Collecting diagnostics before escalating

```bash
OUT=~/pce-diag-$(date +%Y%m%d-%H%M).txt
{
  echo "### $(date -Is) $(whoami)@$(hostname)"
  tailscale status
  kubectl get nodes -o wide
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
  kubectl get svc -A --field-selector spec.type=LoadBalancer
  kubectl get ingress -A
  helm list -A
  kubectl -n longhorn-system get volumes.longhorn.io
  kubectl get clusterpolicies.nvidia.com
  kubectl -n gpu-operator get pods -o wide
  kubectl get events -A --sort-by=.lastTimestamp | tail -50
} > "$OUT" 2>&1
echo "Saved $OUT"
```

Review the file for secrets before sharing it.

### Escalation path

| Level | Who | When |
|---|---|---|
| 1 | On-duty engineer | Follow this README and `passwdrecovery.md` |
| 2 | **barlow** (tailnet owner / access approver) | Tailnet access, jumphost accounts, Rancher permissions, anything in [Known Findings](#5-known-findings-2026-10-21) |
| 3 | **Rancher Government Solutions (RGS) Support**, via the Zendesk link on the Rancher Support page (`https://rancher.pce.denovo/dashboard/support`) | HarvesterOS, Rancher, RKE2, Longhorn, or Carbide product defects; faulted Longhorn volumes; failed upgrades |
| 3 | NVIDIA Enterprise Support | GPU Operator or driver defects after the operator logs have been collected |

Attach the diagnostics file and the output of the failing validation section to every escalation.
