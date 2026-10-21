# NVIDIA GPU Operator on Rancher Government Harvester — v2

Install and validate NVIDIA GPU support on a Harvester node so that the NVIDIA GPU Operator runs on it. Written for the **Denovo PCE** cluster and validated on 2026-10-21 against all five GPU nodes.

> **Driver `595.71.05` · Container toolkit `1.20.0` · GPU Operator `v26.3.3` · Harvester `v1.7.2` · Kernel `6.4.0-49-default`**
> Every GPU node must use the same driver `.run` file for the userspace driver, the kernel modules and the GSP firmware. A mismatch breaks `nvidia-smi` and the GPU Operator validator.

---

## What changed from v1

| Area | v1 | v2 (why) |
|---|---|---|
| Copy/paste | `<NODE_NAME>` placeholders, mixed host/container steps | Set `NODE`/`NODE_IP` once; each block says **where** it runs and is pasted as one unit; host blocks stop on the first error |
| Host shell | "on the HOST" (undefined) | Explicit: `kubectl debug node/... -- chroot /host bash` (no SSH or sudo password needed) |
| Firmware | Copied from `/lib/firmware` after the install | Extracted **directly from the `.run`** into `/usr/local`. `/lib/firmware` is a RAM overlay, and on 3 of 5 nodes the firmware was gone before anyone copied it (`RmInitAdapter failed`) |
| Boot service | No `ldconfig` | **Adds `ExecStart=/sbin/ldconfig`**: `/etc/ld.so.cache` is also a RAM overlay, so after a read-only boot the toolkit can't find `libnvidia-ml` |
| Order | Everything in read-write mode | Persistent pieces (firmware, service, containerd) are done **in normal mode first**; the read-write boot is only for `/usr` and `/lib/modules` |
| Toolkit | `zypper` from GitHub only | Option A `zypper` (node has internet) **or** Option B offline bundle from a working node (what was used on 2026-10-21) |
| Kernel modules | Build pod only | Option A build pod **or** Option B copy from a node with the identical kernel |
| containerd | Blind `cat >>` into `config.toml.tmpl` | Guarded: skips if the `nvidia` runtime is already there (a duplicate TOML table stops containerd) |
| File transfer | `curl` only | Adds `ssh … cat` (Harvester disables SFTP, so `scp` fails with `subsystem request failed`) |
| Validation | `nvidia-smi` | Pre-reboot checklist, GPU Operator pod restart, `gpu-status.sh`, and a read-only reboot test |
| Troubleshooting | 7 entries | 16 entries, including every failure seen on 2026-10-21 |

---

## Cluster reference

| Node | IP | Role (RKE2 unit) | GPU | Firmware file used | BMC |
|---|---|---|---|---|---|
| `hpec1n1` | 192.168.2.111 | control-plane (`rke2-server`) | — | — | 192.168.2.11 |
| `hpec1n2` | 192.168.2.112 | worker (`rke2-agent`) | A2 | `gsp_ga10x.bin` | 192.168.2.12 |
| `hpec1n3` | 192.168.2.113 | control-plane (`rke2-server`) | A40 | `gsp_ga10x.bin` | 192.168.2.13 |
| `hpec2n1` | 192.168.2.115 | control-plane (`rke2-server`) | A2 | `gsp_ga10x.bin` | 192.168.3.11 |
| `hpec2n2` | 192.168.2.116 | worker (`rke2-agent`) | A2 | `gsp_ga10x.bin` | 192.168.3.12 |
| `hpec2n3` | 192.168.2.117 | worker (`rke2-agent`) | A100 PCIe 40GB | `gsp_tu10x.bin` | 192.168.3.13 |

- Driver `.run` is served from `wks`: `http://192.168.2.5/NVIDIA/NVIDIA-Linux-x86_64-595.71.05.run` (file on disk: `/mnt/export/HTML/NVIDIA/`), SHA-256 `36203b8960b7e49c8a42f6ba1f5863cde34a05e93d2b24b798af06dd846f6b82`.
- Chassis-2 BMCs (`192.168.3.x`) are reachable from `wks` only.
- **Control-plane nodes (`hpec1n3`, `hpec2n1`, `hpec1n1`) run etcd.** Reboot only one at a time, and only when the other two are `Ready`.

### Storage layout on a Harvester node (why the steps are ordered this way)

| Path | Backing | Writable in normal boot? | Survives reboot? | Survives OS upgrade? |
|---|---|---|---|---|
| `/`, `/usr`, `/lib/modules` | `/dev/loop0` (`active.img`) | **No** (needs `rd.cos.debugrw`) | Yes | **No** |
| `/lib/firmware` | overlay, upper in `/run` (RAM) | Yes | **No** | No |
| `/etc` (most of it, incl. `ld.so.cache`) | overlay, upper in `/run` (RAM) | Yes | **No** | No |
| `/etc/systemd` | `/usr/local/.state/etc-systemd.bind` | Yes | Yes | Yes |
| `/usr/local`, `/home`, `/var/lib/rancher` | persistent partition | Yes | Yes | Yes |

---

## Prerequisites

- Harvester v1.7.x (RKE2). Each GPU node's kernel: `uname -r` = `6.4.0-49-default`.
- Work from `wks` as `barlow`, with `KUBECONFIG=~/.kube/harvester-cluster.yaml`, `kubectl` v1.34.x, and your SSH key installed for `rancher` on every node (see `passwdrecovery.md`).
- `nvidia-driver-toolkit` Harvester addon **disabled**:

  ```bash
  kubectl get addons.harvesterhci.io -A | grep -i nvidia     # ENABLED column must be false
  ```

- GPU **not** bound to `vfio-pci` (no VM passthrough):

  ```bash
  kubectl get pcidevices.devices.harvesterhci.io -o custom-columns=NODE:.status.nodeName,DEVICE:.status.description,DRIVER:.status.kernelDriverInUse | grep -iE "NODE|nvidia"
  ```

- Console access to the node's GRUB menu (BMC remote console) for the read-write boot.
- About **900 MB free** on the root image (`df -h /` on the node).
- NGC API key, only for first-time operator deployment (Step 9).

---

## Step 0 — Set the target node (on `wks`)

Run this in **every new `wks` terminal** before the other steps:

```bash
NODE=hpec1n2
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
DRV=595.71.05
RUN_URL=http://192.168.2.5/NVIDIA/NVIDIA-Linux-x86_64-${DRV}.run
dbg() { kubectl debug node/"$NODE" -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host sh -c "sleep 5; $1"; }
echo "NODE=$NODE  NODE_IP=$NODE_IP  DRV=$DRV"
curl -sI "$RUN_URL" | head -1          # must be HTTP/1.1 200 OK
```

`dbg '<command>'` runs one command as root on the node and prints the output (the `sleep 5` avoids the `couldn't attach` race that otherwise loses output).

To open an **interactive root shell** on the node (used in Steps 2, 4, 5):

```bash
kubectl debug node/"$NODE" -it --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host bash
```

---

## Step 1 — Pre-checks (on `wks`, read-only)

```bash
dbg '
echo "hostname     : $(hostname)"
echo "kernel       : $(uname -r)"
echo "root mode    : $(findmnt -no OPTIONS / | cut -d, -f1)"
echo "root free    : $(df -h / | awk "NR==2{print \$4}")"
echo "/etc/systemd : $(findmnt -no SOURCE -T /etc/systemd/system)"
echo "gpu (pci)    : $(lspci -nnk -d 10de: | grep -E "controller|Kernel driver" | tr -s " " | paste -sd " ")"
echo "driver now   : $(head -1 /proc/driver/nvidia/version 2>/dev/null | grep -o "[0-9]*\.[0-9]*\.[0-9]*" | head -1 || echo none)"
echo "smi          : $(command -v nvidia-smi || echo none)"
echo "toolkit      : $(nvidia-ctk --version 2>/dev/null | head -1 || echo none)"
echo "service      : $(systemctl is-enabled nvidia-driver-setup.service 2>&1)"
echo "debugrw set  : $(grub2-editenv /oem/grubenv list 2>/dev/null | grep -c debugrw)"'
```

Required before continuing:

- `kernel` is `6.4.0-49-default`, and `/etc/systemd` shows `…[/.state/etc-systemd.bind]`.
- The GPU is listed, and `Kernel driver` is **not** `vfio-pci`.
- `root free` is at least ~900M.

Confirm SSH works (needed for Option B transfers):

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" hostname
```

If it reports `REMOTE HOST IDENTIFICATION HAS CHANGED`, compare the fingerprint first (`dbg 'ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub'`), and only if it matches run `ssh-keygen -R "$NODE_IP"`.

---

## Step 2 — Persistent pieces (normal boot, no reboot)

Everything in this step lives on persistent storage, so it works in a normal read-only boot and survives reboots and OS upgrades.

Open a root shell (Step 0) and paste this **whole block** at once. It stops at the first error:

```bash
bash -e <<'EOS'
DRV=595.71.05
RUN_URL=http://192.168.2.5/NVIDIA/NVIDIA-Linux-x86_64-${DRV}.run
mkdir -p /usr/local/nvidia/installer /usr/local/tmp

# 2a. Download the driver .run to persistent storage (reused in Step 4)
cd /usr/local/nvidia/installer
[ -f NVIDIA-Linux-x86_64-${DRV}.run ] || curl -fSo NVIDIA-Linux-x86_64-${DRV}.run "$RUN_URL"
echo "36203b8960b7e49c8a42f6ba1f5863cde34a05e93d2b24b798af06dd846f6b82  NVIDIA-Linux-x86_64-${DRV}.run" | sha256sum -c -

# 2b. Extract the GSP firmware straight from the .run into /usr/local
rm -rf /usr/local/tmp/nvidia-${DRV}
sh NVIDIA-Linux-x86_64-${DRV}.run -x --target /usr/local/tmp/nvidia-${DRV} >/dev/null
mkdir -p /usr/local/nvidia/firmware/nvidia/${DRV}
find /usr/local/tmp/nvidia-${DRV} -name 'gsp_*.bin' -exec cp -v {} /usr/local/nvidia/firmware/nvidia/${DRV}/ \;
rm -rf /usr/local/tmp/nvidia-${DRV}
ls -lh /usr/local/nvidia/firmware/nvidia/${DRV}/
[ -f /usr/local/nvidia/firmware/nvidia/${DRV}/gsp_ga10x.bin ] && [ -f /usr/local/nvidia/firmware/nvidia/${DRV}/gsp_tu10x.bin ]

# 2c. Boot service: restore firmware, rebuild ld cache, load modules
cat > /etc/systemd/system/nvidia-driver-setup.service <<'EOF'
[Unit]
Description=NVIDIA driver setup (firmware restore + ldconfig + module load, driver 595.71.05)
After=local-fs.target
Before=rke2-server.service rke2-agent.service
ConditionPathExists=/usr/local/nvidia/firmware/nvidia/595.71.05

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mkdir -p /lib/firmware/nvidia/595.71.05
ExecStart=/bin/sh -c 'cp /usr/local/nvidia/firmware/nvidia/595.71.05/*.bin /lib/firmware/nvidia/595.71.05/'
ExecStart=/sbin/ldconfig
ExecStart=/sbin/depmod -a
ExecStart=/sbin/modprobe nvidia
ExecStart=/sbin/modprobe nvidia-uvm
ExecStart=/bin/sh -c 'mknod -m 666 /dev/nvidia-uvm c $(grep nvidia-uvm /proc/devices | cut -d" " -f1) 0 2>/dev/null || true'
ExecStart=/bin/sh -c 'mknod -m 666 /dev/nvidia-uvm-tools c $(grep nvidia-uvm /proc/devices | cut -d" " -f1) 1 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nvidia-driver-setup.service
systemctl is-enabled nvidia-driver-setup.service

# 2d. containerd 'nvidia' runtime (guarded: never add it twice)
C=/var/lib/rancher/rke2/agent/etc/containerd
if grep -q "runtimes.nvidia\]" $C/config.toml; then
  echo "containerd: nvidia runtime already in config.toml (RKE2 detected it) - nothing to do"
elif [ -f $C/config.toml.tmpl ] && grep -q "runtimes.nvidia\]" $C/config.toml.tmpl; then
  echo "containerd: nvidia runtime already in config.toml.tmpl - nothing to do"
else
  [ -f $C/config.toml.tmpl ] || cp $C/config.toml $C/config.toml.tmpl
  cat >> $C/config.toml.tmpl <<'EOF'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
  BinaryName = "/usr/local/bin/nvidia-container-runtime"
EOF
  echo "containerd: nvidia runtime added to config.toml.tmpl (takes effect at next RKE2 start/reboot)"
fi
echo "STEP 2 OK"
EOS
```

Expected: `OK` from `sha256sum`, both `gsp_*.bin` files (about 70M and 29M), `enabled`, a `containerd:` line, then `STEP 2 OK`.

- If the node already has a working driver loaded but no service (as `hpec1n3` did), you can bring the GPU up right now without a reboot. See *Live driver reload* in Troubleshooting.
- The service is enabled now, but on the read-write boot in Step 3 its `modprobe` fails if no kernel modules are installed yet. That's expected; Step 5 restarts it.
- No RKE2 restart is needed here, because the reboots in Steps 3 and 7 restart it.

---

## Step 3 — Maintenance mode, then boot read-write

1. Harvester UI → **Hosts → `$NODE` → ⋮ → Enable Maintenance Mode**. Wait until no VMs remain on the node:

   ```bash
   kubectl get vmi -A -o wide | grep -w "$NODE" || echo "no VMs on $NODE"
   ```

2. Reboot:

   ```bash
   kubectl debug node/"$NODE" -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host systemctl reboot
   ```

3. On the BMC console, at the GRUB menu press `e` on the first entry. Append ` rd.cos.debugrw` to the end of the `linux ($loopdev)$kernel $kernelcmd` line, then press `Ctrl+x`. This is a one-time edit: the next normal reboot drops it.

4. Wait for the node, then confirm read-write mode:

   ```bash
   kubectl wait --for=condition=Ready node/"$NODE" --timeout=15m
   dbg 'findmnt -no OPTIONS / | cut -d, -f1; df -h / | tail -1'     # rw, and ~900M+ free
   ```

   If it shows `ro`, the GRUB edit didn't take. Repeat item 3.

---

## Step 4 — Userspace driver + container toolkit (read-write boot)

Open a root shell (Step 0). Use **one** of the two toolkit options, then the driver block.

### 4a. Container toolkit — Option A: `zypper` (node needs internet)

```bash
bash -e <<'EOS'
findmnt -no OPTIONS / | grep -q '^rw' || { echo "NOT rw - stop"; exit 1; }
zypper --non-interactive addrepo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo || true
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install -y nvidia-container-toolkit-1.20.0 nvidia-container-toolkit-base-1.20.0 libnvidia-container1-1.20.0 libnvidia-container-tools-1.20.0
cp /usr/bin/nvidia-container-runtime /usr/local/bin/nvidia-container-runtime
systemctl enable nvidia-cdi-refresh.path
nvidia-ctk --version | head -1
echo "STEP 4a OK"
EOS
```

### 4a. Container toolkit — Option B: offline bundle from a working node

Used on 2026-10-21 (nodes are air-gapped). Build the bundle once from a healthy node, for example `hpec2n1` (on `wks`):

```bash
REF=hpec2n1; REF_IP=192.168.2.115
mkdir -p ~/gpu-stage
kubectl debug node/$REF -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host sh -c '
  sleep 5
  { rpm -ql nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container1 libnvidia-container-tools
    ls -d /usr/local/bin/nvidia-container-runtime; } \
  | grep -vE "/share/(doc|licenses)|\.build-id" | sort -u | while read f; do [ -e "$f" ] && echo "${f#/}"; done > /home/rancher/nv-toolkit.list
  tar czf /home/rancher/nv-toolkit-1.20.0.tgz -C / -T /home/rancher/nv-toolkit.list
  chown rancher:rancher /home/rancher/nv-toolkit-1.20.0.tgz
  sha256sum /home/rancher/nv-toolkit-1.20.0.tgz'
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@$REF_IP 'cat nv-toolkit-1.20.0.tgz' > ~/gpu-stage/nv-toolkit-1.20.0.tgz
sha256sum ~/gpu-stage/nv-toolkit-1.20.0.tgz
```

Push it to the target node (on `wks`, Step 0 variables set):

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" 'cat > nv-toolkit-1.20.0.tgz' < ~/gpu-stage/nv-toolkit-1.20.0.tgz && echo sent
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" 'sha256sum nv-toolkit-1.20.0.tgz'   # must match wks
```

Install (node root shell):

```bash
bash -e <<'EOS'
findmnt -no OPTIONS / | grep -q '^rw' || { echo "NOT rw - stop"; exit 1; }
tar xzvf /home/rancher/nv-toolkit-1.20.0.tgz -C / --exclude=etc/systemd/system/nvidia-driver-setup.service
systemctl daemon-reload
systemctl enable nvidia-cdi-refresh.path
nvidia-ctk --version | head -1
ls -l /usr/local/bin/nvidia-container-runtime
echo "STEP 4a OK"
EOS
```

> `--exclude` keeps an older copy of the boot service inside the bundle from overwriting the Step 2 version (that's how the `ldconfig` line got lost on `hpec2n3`).

### 4b. Userspace driver (lean, no kernel modules)

Node root shell:

```bash
bash -e <<'EOS'
DRV=595.71.05
findmnt -no OPTIONS / | grep -q '^rw' || { echo "NOT rw - stop"; exit 1; }
df -h / | tail -1
cd /usr/local/nvidia/installer
TMPDIR=/usr/local/tmp sh ./NVIDIA-Linux-x86_64-${DRV}.run --silent --no-questions \
  --no-kernel-modules --no-x-check --no-nouveau-check \
  --no-opengl-files --no-install-compat32-libs --tmpdir=/usr/local/tmp
tail -2 /var/log/nvidia-installer.log
grep -q "is now complete" /var/log/nvidia-installer.log
df -h / | tail -1
ldconfig
ldconfig -p | grep -q libnvidia-ml.so.1
ls -l /usr/bin/nvidia-smi /usr/lib64/libnvidia-ml.so.${DRV}
echo "STEP 4b OK"
EOS
```

If `df` shows the root image near 100% at any point, stop. See *Root image full* in Troubleshooting.

---

## Step 5 — Kernel modules (read-write boot)

Skip this step if the node already has the five 595.71.05 modules:

```bash
dbg 'ls /lib/modules/$(uname -r)/kernel/drivers/video/ | grep -c "^nvidia.*\.ko$"'     # 5 = skip to 5c
```

### 5a. Option A: build with the Harvester toolkit pod

On `wks` (Step 0 variables set):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-install-${NODE}
  namespace: harvester-system
spec:
  nodeName: ${NODE}
  hostPID: true
  restartPolicy: Never
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
kubectl wait --for=condition=Ready pod/nvidia-install-${NODE} -n harvester-system --timeout=180s

kubectl exec -n harvester-system nvidia-install-${NODE} -- bash -ec "
  curl -fSo /tmp/drv.run ${RUN_URL}
  sh /tmp/drv.run --silent --no-questions
  tail -2 /var/log/nvidia-installer.log
  grep -q 'is now complete' /var/log/nvidia-installer.log && echo 'BUILD OK'"

kubectl delete pod -n harvester-system nvidia-install-${NODE}
```

In a second `wks` terminal, watch root-image space during the build: `while sleep 5; do dbg 'df -h / | tail -1'; done`. Abort if it nears 100%.

The installer also writes userspace files and firmware **inside the container**. Those disappear with the pod, which is why Steps 2 and 4 handle them on the host.

### 5b. Option B: copy from a node with the identical kernel

Only when `uname -r` matches the reference node exactly. On `wks`:

```bash
REF=hpec2n1; REF_IP=192.168.2.115
kubectl debug node/$REF -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host sh -c '
  sleep 5; cd / && tar czf /home/rancher/nv-kmod-595.71.05.tgz lib/modules/$(uname -r)/kernel/drivers/video/nvidia*.ko
  chown rancher:rancher /home/rancher/nv-kmod-595.71.05.tgz; tar tzf /home/rancher/nv-kmod-595.71.05.tgz'
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@$REF_IP 'cat nv-kmod-595.71.05.tgz' > ~/gpu-stage/nv-kmod-595.71.05.tgz
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" 'cat > nv-kmod-595.71.05.tgz' < ~/gpu-stage/nv-kmod-595.71.05.tgz && echo sent
sha256sum ~/gpu-stage/nv-kmod-595.71.05.tgz
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" 'sha256sum nv-kmod-595.71.05.tgz'
```

Node root shell:

```bash
bash -e <<'EOS'
findmnt -no OPTIONS / | grep -q '^rw' || { echo "NOT rw - stop"; exit 1; }
tar xzvf /home/rancher/nv-kmod-595.71.05.tgz -C /
echo "STEP 5b OK"
EOS
```

### 5c. Register the modules and load the driver (node root shell)

```bash
bash -e <<'EOS'
K=/lib/modules/$(uname -r)
ls -lh $K/kernel/drivers/video/nvidia*.ko
[ "$(ls $K/kernel/drivers/video/ | grep -c '^nvidia.*\.ko$')" -eq 5 ]
depmod -a
[ "$(grep -c 'video/nvidia' $K/modules.dep)" -ge 5 ]
modinfo -F version nvidia
lsmod | grep -q '^nvidia ' && { rmmod nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm nvidia 2>/dev/null || true; }
systemctl restart nvidia-driver-setup.service
systemctl is-active nvidia-driver-setup.service
nvidia-smi -L
nvidia-container-cli info | grep -m1 Model
echo "STEP 5 OK"
EOS
```

Expected: five modules, `595.71.05`, `active`, and the GPU model from both `nvidia-smi` and `nvidia-container-cli`.

---

## Step 6 — Validate before the normal reboot (on `wks`)

### 6a. Host checklist, compared with a known-good node

```bash
for n in hpec2n1 "$NODE"; do
  kubectl debug node/$n -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host sh -c '
    sleep 5; K=/lib/modules/$(uname -r)
    echo "################ $(hostname)"
    echo "root mode     : $(findmnt -no OPTIONS / | cut -d, -f1)"
    echo "kernel mods   : $(ls $K/kernel/drivers/video/ | grep -c "^nvidia.*\.ko$") files, modules.dep: $(grep -c "video/nvidia" $K/modules.dep)"
    echo "loaded driver : $(head -1 /proc/driver/nvidia/version 2>/dev/null | grep -o "[0-9]*\.[0-9]*\.[0-9]*" | head -1)"
    echo "fw persistent : $(ls /usr/local/nvidia/firmware/nvidia/595.71.05/ 2>&1 | tr "\n" " ")"
    echo "svc           : $(systemctl is-enabled nvidia-driver-setup.service) / $(systemctl is-active nvidia-driver-setup.service)"
    echo "svc ldconfig  : $(grep -c "^ExecStart=/sbin/ldconfig" /etc/systemd/system/nvidia-driver-setup.service)"
    echo "cdi path      : $(systemctl is-enabled nvidia-cdi-refresh.path 2>&1)"
    echo "installer     : $(grep "installer version" /var/log/nvidia-installer.log)"
    echo "toolkit       : $(nvidia-ctk --version 2>&1 | head -1)"
    echo "runtime bin   : $(ls /usr/local/bin/nvidia-container-runtime 2>&1)"
    echo "containerd rt : $(grep -c "runtimes.nvidia\]" /var/lib/rancher/rke2/agent/etc/containerd/config.toml)"
    echo "ldcache       : $(ldconfig -p | grep -c libnvidia-ml)"
    echo "gpu (smi)     : $(nvidia-smi -L 2>&1 | sed "s/ (UUID.*//")"
    echo "gpu (toolkit) : $(nvidia-container-cli info 2>&1 | grep -m1 -E "Model|error")"
    echo "debugrw set   : $(grub2-editenv /oem/grubenv list 2>/dev/null | grep -c debugrw)"'
done
```

The target node must match the reference on every line except `root mode` (`rw` for now). Critical lines:

| Line | Must be | If not |
|---|---|---|
| `kernel mods` | `5 files, modules.dep: 5` | Step 5 |
| `fw persistent` | `gsp_ga10x.bin gsp_tu10x.bin` | Step 2b |
| `svc` | `enabled / active` | Step 2c / 5c |
| `svc ldconfig` | `1` | Step 2c |
| `toolkit` / `runtime bin` | `1.20.0` / present | Step 4a |
| `containerd rt` | `1` | Step 2d, then reboot |
| `gpu (toolkit)` | GPU model | Steps 4–5 |
| `debugrw set` | `0` | Remove it, or the next boot will be read-write again |

### 6b. End-to-end: GPU Operator pods

```bash
kubectl -n gpu-operator delete pod --field-selector spec.nodeName="$NODE" \
  -l 'app in (gpu-feature-discovery,nvidia-device-plugin-daemonset,nvidia-dcgm-exporter,nvidia-operator-validator)'
sleep 90
kubectl -n gpu-operator get pods -o wide --field-selector spec.nodeName="$NODE"
./gpu-status.sh
```

Expected: `nvidia-operator-validator`, `nvidia-device-plugin-daemonset`, `gpu-feature-discovery` and `nvidia-dcgm-exporter` are `Running`, `nvidia-cuda-validator` is `Completed`, and `gpu-status.sh` shows the node `OK`. On the A100, `nvidia-mig-manager` also runs. If not `OK` after 3 minutes, see Troubleshooting.

---

## Step 7 — Normal reboot (read-only) and final verification

Still in maintenance mode:

```bash
kubectl debug node/"$NODE" -q -i --profile=sysadmin --image=registry.suse.com/bci/bci-base -- chroot /host systemctl reboot
sleep 60
kubectl wait --for=condition=Ready node/"$NODE" --timeout=15m
sleep 150
dbg '
echo "root: $(findmnt -no OPTIONS / | cut -d, -f1)  svc: $(systemctl is-active nvidia-driver-setup.service)  ldc: $(ldconfig -p | grep -c libnvidia-ml)  fw: $(ls /lib/firmware/nvidia/595.71.05/ | wc -l)"
nvidia-smi -L
nvidia-container-cli info | grep -m1 Model'
kubectl -n gpu-operator get pods -o wide --field-selector spec.nodeName="$NODE"
./gpu-status.sh
```

Pass: `root: ro`, `svc: active`, `ldc` ≥ 1, `fw: 2`, the GPU model in both outputs, and the node `OK`, with no manual steps after boot.

Then Harvester UI → **Hosts → `$NODE` → ⋮ → Disable Maintenance Mode**, and clean up:

```bash
kubectl get pods -n default --no-headers | awk '/^node-debugger-/ {print $1}' | xargs -r kubectl delete pod -n default
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa -o LogLevel=ERROR rancher@"$NODE_IP" 'rm -f nv-*.tgz'
```

Repeat Steps 0–7 for the next node (one node at a time; control-plane nodes only when the other two are `Ready`).

---

## Step 8 — Cluster-wide verification

```bash
./gpu-status.sh
kubectl -n gpu-operator get ds
kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | "\(.metadata.name)  \(.metadata.labels["nvidia.com/gpu.product"])  allocatable=\(.status.allocatable["nvidia.com/gpu"])"'
```

Target: all five GPU nodes `OK`; `gpu-feature-discovery`, `nvidia-device-plugin-daemonset`, `nvidia-dcgm-exporter`, `nvidia-operator-validator` all `5/5`; `nvidia-mig-manager` `1/1` (A100 only); each GPU node `allocatable=1`.

---

## Step 9 — Deploy the GPU Operator (once per cluster)

Already deployed on Denovo PCE (chart `gpu-operator-v26.3.3`). Use this only for a new cluster or a reinstall.

```bash
kubectl create namespace gpu-operator
kubectl label namespace gpu-operator \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/warn-version=latest
```

Create the pull secret. The username is the literal string `$oauthtoken`; `read -s` keeps the key out of shell history:

```bash
read -rsp "NGC API key: " NGC_KEY; echo
kubectl create secret docker-registry ngc-secret -n gpu-operator \
  --docker-server=nvcr.io --docker-username='$oauthtoken' --docker-password="$NGC_KEY"
unset NGC_KEY
kubectl get secret ngc-secret -n gpu-operator
```

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
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
kubectl -n gpu-operator get pods -o wide
```

Air-gapped: `helm pull nvidia/gpu-operator --version=v26.3.3` on a connected machine, copy the `.tgz`, and use its path instead of `nvidia/gpu-operator`.

Notes carried over from v1 (all still valid):

- **No `hostPaths.driverInstallDir`.** The driver is in standard host paths (driver root `/`).
- `driver.useOpenKernelModules` and the `toolkit.env` `CONTAINERD_*` settings do nothing with `driver.enabled=false` / `toolkit.enabled=false`.
- NFD workers run on every node. The **NFD master** applies the GPU labels; if it's stuck on an unhealthy node, delete it so it reschedules.
- Rollout: NFD → labels (`feature.node.kubernetes.io/pci-10de.present=true`, `nvidia.com/gpu.present=true`) → validator, device plugin, GFD, DCGM on GPU nodes → `nvidia-cuda-validator` `Completed` → `nvidia.com/gpu` allocatable.

---

## Step 10 — CUDA workload test

```bash
kubectl run nvidia-cuda-test --restart=Never \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1 \
  --overrides='{"spec":{"runtimeClassName":"nvidia","nodeSelector":{"kubernetes.io/hostname":"'"$NODE"'"},"containers":[{"name":"cuda-sample","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nvidia-cuda-test --timeout=180s
kubectl logs nvidia-cuda-test
kubectl delete pod nvidia-cuda-test
```

Expected: `Test PASSED`. The `nodeSelector` pins the test to `$NODE`. If the image can't be pulled, mirror it into `registry.pce.denovo` first.

---

## Troubleshooting

### Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `nvidia-smi`: `No devices were found`; dmesg `Direct firmware load for nvidia/595.71.05/gsp_*.bin failed`, `RmInitAdapter failed! (0x61:0x56:2074)` | GSP firmware missing from `/lib/firmware` (RAM overlay) | Step 2b + 2c, then *Live driver reload* below. A2/A40 need `gsp_ga10x.bin`; A100 needs `gsp_tu10x.bin` |
| Validator `driver-validation` repeats `Attempting to validate a driver container installation` | Host `nvidia-smi` is failing (it falls back to looking for a driver container) | Fix `nvidia-smi` on the host (usually the firmware), then delete the validator pod |
| GPU pods `Init` with **no IP** for a long time; event `no runtime for "nvidia" is configured` | No `nvidia` runtime in containerd | Step 4a (toolkit) + 2d, then reboot or restart RKE2 |
| Validator `toolkit-validation`: `fork/exec /usr/bin/nvidia-ctk: no such file or directory` | Toolkit binaries missing | Step 4a (needs the read-write boot) |
| `nvidia-container-cli: load library failed: libnvidia-ml.so.1` / `ldcache` = 0 | `/etc/ld.so.cache` (RAM overlay) lost at boot | `ldconfig` now; make sure the service has `ExecStart=/sbin/ldconfig` (Step 2c) |
| `mount: /: cannot remount /dev/loop0 read-write, is write-protected` | The loop device is read-only in a normal boot | Boot with `rd.cos.debugrw` (Step 3); `remount,rw` does not work |
| `tar: usr/...: Cannot open: Read-only file system` | Not in the read-write boot | Step 3 |
| `systemctl enable` → `Unit file nvidia-cdi-refresh.path does not exist` | Toolkit not installed | Step 4a, then re-run the enable |
| `scp`: `subsystem request failed on channel 0` | SFTP disabled on Harvester | `ssh … 'cat > file' < file` (as used throughout) |
| `ssh` silently does nothing with `-q` | `-q` hides errors (host key, auth) | Use `-o LogLevel=ERROR` instead |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Node reinstalled, **or** interception | Verify the fingerprint via `dbg 'ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub'` before `ssh-keygen -R` |
| `kubectl debug` prints nothing / `couldn't attach … falling back to streaming logs` | The command finished before kubectl attached | Start the command with `sleep 5` (the `dbg` helper does this) |
| `systemd` unit fails `status=203/EXEC` | Wrong path in `ExecStart` | `depmod`/`modprobe`/`ldconfig` live in `/sbin` |
| `depmod: failed to load symbols from nvidia.ko` / `modprobe` segfault | Truncated `.ko` (disk full during build) | Delete `$K/kernel/drivers/video/nvidia*.ko`, free space, redo Step 5 |
| `Driver/library version mismatch` | Userspace ≠ kernel module version | Same `.run` for Steps 4b and 5 |
| Root image full / installer log ends abruptly | Full (non-lean) install or leftovers | Free space (`zypper clean -a`, `journalctl --vacuum-size=20M`), delete orphans: `find /usr/lib64 /usr/lib -name '*595.71.05*' -delete; find /usr/lib64 /usr/lib -xtype l -delete; ldconfig`, reinstall with lean flags. **Never delete `libnvidia-container*` or `/usr/bin/nvidia-container-*`** (toolkit) |
| Pods stuck `ContainerCreating`: `Multus … Unauthorized` | Stale Multus token on the node | Delete the node's `kube-multus` pod in `kube-system`; check `timedatectl` |
| NFD master stuck → no GPU labels anywhere | It landed on an unhealthy node | `kubectl -n gpu-operator delete pod -l app.kubernetes.io/component=master` |
| `nvidia-mig-manager` appears on one node | That node has a MIG-capable GPU (A100) | Expected; MIG is not configured, so the GPU is used whole |

### Live driver reload (no reboot)

Use when the modules are installed but the GPU failed to initialize (for example, the firmware was missing). It affects only the GPU driver, and nothing may be using the GPU. Node root shell:

```bash
bash -e <<'EOS'
lsmod | grep '^nvidia' || true
rmmod nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm nvidia 2>/dev/null || rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia
systemctl restart nvidia-driver-setup.service
nvidia-smi -L
dmesg | grep -iE "NVRM|firmware load" | tail -3
EOS
```

If `rmmod` reports `in use`, stop and reboot instead (one control-plane node at a time).

Then delete the node's GPU Operator pods (Step 6b).

### Find out why a validator is stuck

```bash
POD=$(kubectl -n gpu-operator get pods -l app=nvidia-operator-validator --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
kubectl -n gpu-operator get pod "$POD" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{": "}{.state.waiting.message}{.lastState.terminated.message}{"\n"}{end}'
kubectl -n gpu-operator logs "$POD" -c driver-validation --tail=5
kubectl -n gpu-operator get events --field-selector involvedObject.name="$POD" --sort-by=.lastTimestamp | tail -5
```

---

## After every Harvester OS upgrade

The upgrade replaces `active.img`, wiping `/usr` (userspace driver, toolkit) and `/lib/modules` (kernel modules). These persist: `/usr/local/nvidia` (firmware, `.run`), `/usr/local/bin/nvidia-container-runtime`, `/etc/systemd/system/nvidia-driver-setup.service`, and `config.toml.tmpl`.

For each GPU node, one at a time:

1. Step 0 and Step 1. Check the **new kernel** with `uname -r`. If it changed, the copied modules (Option 5b) won't load, so use Option 5a (build pod with a toolkit image matching the new Harvester version).
2. Step 3 (read-write boot) → Step 4 (toolkit + userspace) → Step 5 (modules) → Steps 6–7.
3. Step 2 is already in place; re-run it only if `/usr/local/nvidia` or the service is missing.
