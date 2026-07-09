# NVIDIA GPU Operator on Rancher Government Harvester

This guide covers the full process to enable NVIDIA GPU support on Harvester using the NVIDIA GPU Operator.

> **Driver version used throughout: `595.71.05`.** The same `.run` file MUST be used in Step 2 (host userspace) and Step 4 (kernel modules). A version mismatch between userspace and kernel modules will break `nvidia-smi` and the GPU Operator validator.

## Prerequisites

- Harvester v1.7.1 cluster (RKE2)
- NVIDIA GPU installed (tested with A2, A40, L40)
- NVIDIA GPU Driver downloaded (https://www.nvidia.com/en-in/drivers)... make sure to use the `Linux 64-bit` version of the `.run`
- NVIDIA GPU Driver documentation can be helpful as well... https://docs.nvidia.com/datacenter/tesla/index.html
- Serve the NVIDIA driver `.run` file from an HTTP Server accessible to each of the nodes on the cluster
- NVIDIA NGC API key (https://org.ngc.nvidia.com/account/api-keys) for pulling images from `nvcr.io`
- Ensure the `nvidia-driver-toolkit` addon **disabled** in the Harvester UI
- NVIDIA GPU must not be bound to `vfio-pci` — unassign any VM PCIe passthrough first
- **Root image free space.** The Harvester root filesystem is a small (~3 GB) loop-mounted image (`/cOS/active.img`), and both the driver userspace AND `/lib/modules` live on it. Check `df -h /` before starting — you need roughly **800 MB free** for the lean userspace install plus **~110 MB** for the kernel modules. If space runs out mid-install, the installer fails silently and leaves corrupt/truncated files behind (see Troubleshooting).

---

## Step 1 - Boot Node with Writable Rootfs

Harvester uses an immutable OS. To install packages, reboot into GRUB with the `rd.cos.debugrw` flag.

1. Reboot the GPU node
2. At the GRUB menu, press `e` on the first entry
3. Append `rd.cos.debugrw` to the end of the `linux ($loopdev)$kernel $kernelcmd` line
4. Press `Ctrl+x` to boot

Verify the rootfs is writable after boot:

```bash
touch /usr/bin/test && echo "writable" && rm /usr/bin/test
```

Check free space on the root image before proceeding:

```bash
df -h /
# need ~900 MB+ free; clean up (zypper clean -a, journalctl --vacuum-size=20M) if short
```

---

## Step 2 - Install NVIDIA Userspace Components

Install `nvidia-container-toolkit` and the NVIDIA userspace driver components while the rootfs is writable. The `.run` installer puts `nvidia-smi`, `libcuda`, `libnvidia-ml`, and other libraries into `/usr/bin` and `/usr/lib64` on the host. Copy `nvidia-container-runtime` to `/usr/local/bin` so it persists across reboots.

> **Lean install flags are mandatory.** `--no-opengl-files --no-install-compat32-libs` skips ~350 MB of 32-bit and graphics libraries that are not needed for compute workloads and will not fit on the root image. A full install WILL exhaust the 3 GB root image.

```bash
# install nvidia container toolkit
zypper addrepo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
zypper refresh
zypper install -y nvidia-container-toolkit
cp /usr/bin/nvidia-container-runtime /usr/local/bin/nvidia-container-runtime

# install nvidia userspace components (no kernel modules, lean/compute-only)
curl -o /tmp/NVIDIA-Linux-x86_64-595.71.05.run http://<HAULER_FILESERVER_IP>:8080/NVIDIA-Linux-x86_64-595.71.05.run
chmod +x /tmp/NVIDIA-Linux-x86_64-595.71.05.run
/tmp/NVIDIA-Linux-x86_64-595.71.05.run --silent --no-questions \
  --no-kernel-modules --no-x-check --no-nouveau-check \
  --no-opengl-files --no-install-compat32-libs

# verify the install actually completed (a disk-full failure can be silent)
tail -5 /var/log/nvidia-installer.log      # must end with "is now complete"
df -h /                                    # must NOT be at 100%

# verify binaries and libraries
which nvidia-smi
which nvidia-container-runtime
ldconfig -p | grep libnvidia-ml            # must list libnvidia-ml.so.1
```

Note: this install also places the GSP firmware at `/lib/firmware/nvidia/595.71.05/` (`gsp_ga10x.bin`, `gsp_tu10x.bin`). That path is a tmpfs-backed overlay and **does not survive reboots** — persistence is handled in Step 4c/4d.

---

## Step 3 - Configure Containerd and registries.yaml

### Step 3a - containerd

RKE2 regenerates `config.toml` on restart. Use `config.toml.tmpl` to persist the nvidia runtime — this file is on the persistent partition and survives reboots.

```bash
cp /var/lib/rancher/rke2/agent/etc/containerd/config.toml \
   /var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl

cat >> /var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl << 'EOF'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
  BinaryName = "/usr/local/bin/nvidia-container-runtime"
EOF

# verify
cat /var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl
```

### Step 3b - Restart RKE2

```bash
# control plane nodes
systemctl restart rke2-server

# worker nodes
systemctl restart rke2-agent

# verify
crictl info | grep -A3 nvidia
```

---

## Step 4 - Compile Kernel Modules and Install Driver

The Harvester OS does not have gcc. Kernel modules are compiled inside the Harvester toolkit container image which includes gcc and kernel headers.

> **Correction to the previous version of this doc:** the compiled modules are written to `/lib/modules`, which on this hardware lives on the **root loop image**, not the persistent data partition. This means (a) the module install consumes root-image space (~110 MB for the 5 open-driver modules), and (b) the modules are wiped by any Harvester OS upgrade that replaces `active.img` — Steps 2 and 4 must be redone after every OS upgrade.

### Step 4a - Deploy a privileged install pod on the GPU node

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-install-<NODE_NAME>
  namespace: harvester-system
spec:
  nodeName: <NODE_NAME>
  hostPID: true
  containers:
  - name: install
    image: rancher/harvester-nvidia-driver-toolkit:v1.7-20260209
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
    - name: modules
      mountPath: /lib/modules
  volumes:
  - name: host
    hostPath:
      path: /
  - name: modules
    hostPath:
      path: /lib/modules
EOF

kubectl wait --for=condition=Ready pod/nvidia-install-<NODE_NAME> -n harvester-system --timeout=120s
```

> If saving the manifest to a file instead of piping the heredoc, remove the `cat <<EOF | kubectl apply -f -` line and the trailing `EOF` — they are shell syntax, not YAML.

### Step 4b - Exec into the Container and Run the NVIDIA Installer

While the installer runs, keep `watch -n5 df -h /` running in a second terminal **on the host**. If the root image approaches 100%, abort (Ctrl+C) immediately — a disk-full write produces a corrupt `.ko` that later segfaults modprobe.

```bash
# exec into container
kubectl exec -it -n harvester-system nvidia-install-<NODE_NAME> -- bash
```

```bash
# inside the container — full install, kernel modules included
curl -o /tmp/NVIDIA-Linux-x86_64-595.71.05.run http://<HAULER_FILESERVER_IP>:8080/NVIDIA-Linux-x86_64-595.71.05.run
chmod +x /tmp/NVIDIA-Linux-x86_64-595.71.05.run
/tmp/NVIDIA-Linux-x86_64-595.71.05.run --silent --no-questions

# verify BEFORE exiting the container
tail -5 /var/log/nvidia-installer.log      # must end with "is now complete"
```

This compiles all five open kernel modules (`nvidia.ko`, `nvidia-uvm.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-peermem.ko`) and writes them to `/lib/modules` on the host. Verify from the host after exiting:

```bash
find /usr/lib/modules/$(uname -r) -name 'nvidia*.ko' -exec ls -lh {} \;   # expect 5 modules
df -h /
depmod -a                          # must complete silently
modinfo nvidia | grep ^version     # must print 595.71.05
modprobe nvidia
nvidia-smi                         # GPU should be visible
```

### Step 4c - Copy GSP Firmware to Persistent Storage

The GSP firmware is required for Turing/Ampere/Ada GPUs (A2, A40, L40, etc.) but `/lib/firmware` is a tmpfs-backed overlay that does not persist across reboots. The Step 2 host install already placed the firmware there; copy it to persistent storage (`/usr/local` is on the persistent data partition):

```bash
# on the HOST (not inside the container)
mkdir -p /usr/local/nvidia/firmware/nvidia/595.71.05
cp /lib/firmware/nvidia/595.71.05/*.bin /usr/local/nvidia/firmware/nvidia/595.71.05/
ls -lh /usr/local/nvidia/firmware/nvidia/595.71.05/   # expect gsp_ga10x.bin (~70M), gsp_tu10x.bin (~29M)
```

### Step 4d - Create Systemd Service for Boot Persistence

Since `/lib/firmware` is an overlay, the firmware restore and kernel module loads must run on every boot. `/etc/systemd` is on the persistent partition so the service survives reboots.

> Note: `depmod` and `modprobe` are at `/sbin/` on Harvester, not `/usr/bin/` — systemd `ExecStart` requires absolute paths and fails with `status=203/EXEC` if the path is wrong. Verify with `which depmod modprobe` if unsure.

```bash
cat > /etc/systemd/system/nvidia-driver-setup.service << 'EOF'
[Unit]
Description=NVIDIA driver setup (firmware restore + module load, driver 595.71.05)
After=local-fs.target
Before=rke2-server.service rke2-agent.service
ConditionPathExists=/usr/local/nvidia/firmware/nvidia/595.71.05

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mkdir -p /lib/firmware/nvidia/595.71.05
ExecStart=/bin/sh -c 'cp /usr/local/nvidia/firmware/nvidia/595.71.05/*.bin /lib/firmware/nvidia/595.71.05/'
ExecStart=/sbin/depmod -a
ExecStart=/sbin/modprobe nvidia
ExecStart=/sbin/modprobe nvidia-uvm
ExecStart=/bin/sh -c 'mknod -m 666 /dev/nvidia-uvm c $(grep nvidia-uvm /proc/devices | cut -d" " -f1) 0 2>/dev/null || true'
ExecStart=/bin/sh -c 'mknod -m 666 /dev/nvidia-uvm-tools c $(grep nvidia-uvm /proc/devices | cut -d" " -f1) 1 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nvidia-driver-setup.service

# verify
systemctl status nvidia-driver-setup.service   # active (exited), all ExecStart SUCCESS
lsmod | grep nvidia
ls /dev/nvidia*
nvidia-smi
```

### Step 4e - Clean Up and Reboot Test

```bash
kubectl delete pod -n harvester-system nvidia-install-<NODE_NAME>
```

**Do a controlled reboot of the node now** (normal boot — no GRUB edits) and verify everything survives before deploying the operator:

```bash
systemctl status nvidia-driver-setup.service
lsmod | grep nvidia
nvidia-smi
ls /lib/firmware/nvidia/595.71.05/
```

---

## Step 5 - Deploy GPU Operator

Performed once per cluster.

```bash
# create namespace
kubectl create namespace gpu-operator

# label namespace for security
kubectl label namespace gpu-operator pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/audit-version=latest pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/warn-version=latest

# create nvcr registry secret
# username is the literal string $oauthtoken (keep the single quotes);
# password is the NGC API key (nvapi-...). Do NOT forget -n gpu-operator —
# without it the secret lands in the default namespace and pulls fail.
kubectl create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=<NVCR_API_TOKEN> \
  -n gpu-operator

# verify
kubectl get secret ngc-secret -n gpu-operator

# add helm chart repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# (air-gapped alternative: helm pull nvidia/gpu-operator --version=v26.3.3 on a
# connected machine, move the .tgz over, and install from the file path instead
# of nvidia/gpu-operator)

# install the helm chart
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version=v26.3.3 \
  -n gpu-operator \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --set operator.defaultRuntime=containerd \
  --set 'operator.imagePullSecrets[0]=ngc-secret' \
  --set 'daemonsets.imagePullSecrets[0]=ngc-secret' \
  --set-string "validator.driver.env[0].name=DISABLE_DEV_CHAR_SYMLINK_CREATION" \
  --set-string "validator.driver.env[0].value=true"

# verify
kubectl get pods -n gpu-operator -o wide -w
```

Changes from the previous version of this doc, all verified in the field:

- **Removed `hostPaths.driverInstallDir=/usr/local`.** The driver is pre-installed into standard system paths (driver root `/`); pointing the operator at `/usr/local` makes the validator look for the driver in the wrong place and fail. Only set this when the operator itself manages the driver.
- **Removed `driver.useOpenKernelModules` and `driver.imagePullSecrets`** — inert with `driver.enabled=false` (the open modules are chosen at Step 4 by the `.run` installer; 595.x builds open modules by default, which is correct for Turing+).
- **Removed the `toolkit.env` CONTAINERD_* settings** — inert with `toolkit.enabled=false` (containerd was configured manually in Step 3). For reference if ever running with the toolkit enabled: `CONTAINERD_CONFIG=/var/lib/rancher/rke2/agent/etc/containerd/config.toml`, `CONTAINERD_SOCKET=/run/k3s/containerd/containerd.sock`.
- **Pull secrets set explicitly on `operator.imagePullSecrets` and `daemonsets.imagePullSecrets`** — these reliably propagate to all operator and daemonset pods.
- **Removed `kubectl delete pods -n gpu-operator --all --force`** — not needed; the rollout converges on its own within a few minutes.
- **NFD**: the chart deploys Node Feature Discovery as a sub-chart, and NFD workers run on **every** node (GPU or not) — that is how GPU nodes are discovered (PCI vendor ID `10de`). If the cluster already runs NFD from another source, add `--set nfd.enabled=false`. Important: the NFD **master** pod applies the node labels; if it lands on an unhealthy node and cannot start, no node ever gets labeled and no GPU pods schedule. If stuck, `kubectl delete pod` it so it reschedules to a healthy node.

Rollout sequence to expect: NFD pods Running → node labeled (`nvidia.com/gpu.present=true`, `feature.node.kubernetes.io/pci-10de.present=true`) → `nvidia-operator-validator`, `nvidia-device-plugin-daemonset`, `gpu-feature-discovery`, `nvidia-dcgm-exporter` scheduled to GPU nodes → `nvidia-cuda-validator` Completed → GPU registered.

```bash
# final verification
kubectl describe node <NODE_NAME> | grep -A2 nvidia.com/gpu
# expect nvidia.com/gpu: 1 under both Capacity and Allocatable
```

---

## Step 6 - Test GPU with CUDA Workload

```bash
kubectl run nvidia-cuda-test \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1 \
  --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"cuda-sample","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'

kubectl logs nvidia-cuda-test
kubectl delete pod nvidia-cuda-test
```

Expected output: `Test PASSED`

(`runtimeClassName: nvidia` is created by the operator and matches the runtime name added in Step 3a — verify with `kubectl get runtimeclass` if the pod fails to start.)

---

## Troubleshooting (lessons learned)

**Symptom: `.run` installer log ends abruptly / uninstaller says "There is no NVIDIA driver currently installed" despite files being present.**
The installer ran out of disk space mid-install and died before registering itself. Files present are orphans. Fix: free space, remove orphans by version suffix (`find /usr/lib64 /usr/lib -name '*595.71.05*' -delete`, then `find /usr/lib64 /usr/lib -xtype l -delete`, then `ldconfig`), and reinstall with the lean flags. **Never delete `libnvidia-container*.so*` or the May-timestamped `/usr/bin/nvidia-container-*` binaries — those belong to the zypper container toolkit, not the driver.**

**Symptom: `depmod: failed to load symbols from nvidia.ko: Invalid argument` and/or `modprobe` segfaults.**
Corrupt/truncated `.ko`, written while the disk was full. Delete all `nvidia*.ko` under `/usr/lib/modules/$(uname -r)`, free space, and re-run the Step 4 container install. (Ignore `kernel/drivers/net/ethernet/nvidia/` — that is the stock kernel's NVIDIA ethernet driver.)

**Symptom: `nvidia-smi` → "couldn't find libnvidia-ml.so".**
Userspace install incomplete or ldconfig stale. Check `ldconfig -p | grep libnvidia-ml`; if missing, re-run Step 2.

**Symptom: `nvidia-smi` → "Driver/library version mismatch".**
Host userspace version ≠ kernel module version. Use the identical `.run` for Steps 2 and 4.

**Symptom: modules load but GPU fails to initialize; dmesg shows NVRM firmware errors.**
GSP firmware missing from `/lib/firmware/nvidia/<version>/` (tmpfs overlay wiped by a reboot). Confirm the systemd unit from Step 4d ran: `systemctl status nvidia-driver-setup`.

**Symptom: systemd unit fails with `status=203/EXEC`.**
Wrong absolute path in ExecStart. `depmod`/`modprobe` are at `/sbin/` on Harvester.

**Symptom: pods stuck ContainerCreating with `Multus ... error waiting for pod: Unauthorized`.**
Node-level CNI auth issue (stale Multus serviceaccount token), unrelated to GPU work. Delete the multus pod in `kube-system` on the affected node so it regenerates its token; check `timedatectl` for clock drift. If the stuck pod is the NFD **master**, delete it too so it reschedules to a healthy node — it gates node labeling cluster-wide.

**After every Harvester OS upgrade:** the root image (`active.img`) is replaced, wiping the driver userspace AND the kernel modules. Redo Steps 1, 2, and 4 (Step 3's `config.toml.tmpl`, Step 4c's firmware copy in `/usr/local`, and the systemd unit persist). Check `df -h /` first — the fresh image may have different free space.
