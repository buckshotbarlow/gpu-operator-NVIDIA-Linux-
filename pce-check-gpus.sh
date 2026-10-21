#!/usr/bin/env bash
# Denovo PCE - NVIDIA GPU Operator status across all Harvester nodes
#   ./gpu-status.sh                         colored table (green GOOD / yellow OK / red FAIL)
#   ./gpu-status.sh --html > gpu-status.html  email-ready table: open in a browser, select all, paste into the email
#   ./gpu-status.sh --plain                 no colors (tickets, logs)
#   ./gpu-status.sh --verbose               add NFD, CUDA validator and operator-role columns
# Exit code = number of GPU nodes in FAIL (0 = none).

set -u
MODE=term; VERBOSE=0
for a in "$@"; do
  case $a in
    --html) MODE=html ;; --plain) MODE=plain ;; -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 99 ;;
  esac
done
if [ "$MODE" = term ] && { [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; }; then MODE=plain; fi

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/harvester-cluster.yaml}"
NS=gpu-operator
for t in kubectl jq; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 99; }; done

PODS=$(kubectl -n "$NS" get pods -o json)  || { echo "cannot list $NS pods"; exit 99; }
NODES_JSON=$(kubectl get nodes -o json)    || { echo "cannot list nodes"; exit 99; }
PCI=$(kubectl get pcidevices.devices.harvesterhci.io -o json 2>/dev/null || echo '{"items":[]}')
DS=$(kubectl -n "$NS" get ds -o custom-columns=N:.metadata.name,D:.status.desiredNumberScheduled,R:.status.numberReady --no-headers 2>/dev/null)

OPVER=$(kubectl -n "$NS" get deploy gpu-operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
[ -z "$OPVER" ] && OPVER=$(jq -r '[.items[] | select(.metadata.name|test("^gpu-operator-[0-9a-f]+-[a-z0-9]+$")) | .spec.containers[0].image][0] // "unknown"' <<< "$PODS" | sed 's/.*://')
CPSTATE=$(kubectl get clusterpolicies.nvidia.com -o jsonpath='{.items[0].status.state}' 2>/dev/null); CPSTATE=${CPSTATE:-unknown}
NOW=$(date '+%Y-%m-%d %H:%M %Z')

# ---- data helpers -----------------------------------------------------------
# Status of the first pod on node $1 whose name matches regex $2
st() {
  jq -r --arg n "$1" --arg re "$2" '
    def hard: [.status.containerStatuses[]?, .status.initContainerStatuses[]? | .state.waiting.reason // empty
               | select(test("CrashLoopBackOff|RunContainerError|CreateContainer|ImagePull|ErrImage"))];
    [.items[] | select(.spec.nodeName==$n and (.metadata.name|test($re)))] | .[0] |
    if . == null then "-"
    else (now - ((.metadata.creationTimestamp // null) | if . == null then now else fromdateiso8601 end)) as $age |
      if .status.phase == "Succeeded" then "Completed"
      elif .status.phase == "Running" and ([.status.containerStatuses[]?.ready] | all) then "Running"
      elif (hard | length) > 0 then (hard[0] | sub("CrashLoopBackOff";"CrashLoop") | sub("RunContainerError";"RunError")
                                     | sub("CreateContainer.*";"CreateErr") | sub("ImagePullBackOff|ErrImagePull";"ImagePull"))
      elif $age < 180 then "Starting"
      elif .status.podIP == null then "NoSandbox"
      elif ([.status.initContainerStatuses[]? | select(.ready | not)] | length) > 0 then (if $age > 600 then "Stuck" else "Init" end)
      elif .status.phase == "Running" then (if $age > 600 then "NotReady" else "Starting" end)
      else .status.phase end
    end' <<< "$PODS"
}

# Classify a value: good | warn | bad
cls() {
  case "$1" in
    Running|Completed|nvidia|[0-9]*.[0-9]*.[0-9]*) echo good ;;
    Init|Starting|Pending|PodInitializing|ContainerCreating) echo warn ;;
    *) echo bad ;;
  esac
}

# ---- collect rows -----------------------------------------------------------
ROWS=()        # each row: fields separated by |
GOOD=0; OKC=0; FAIL=0; NOGPU=0
for n in $(jq -r '.items[].metadata.name' <<< "$NODES_JSON" | sort); do
  ngpu=$(jq -r --arg n "$n" '[.items[] | select(.status.nodeName==$n and (.status.description|test("NVIDIA")))] | length' <<< "$PCI")
  label=$(jq -r --arg n "$n" '.items[] | select(.metadata.name==$n) | .metadata.labels["nvidia.com/gpu.product"] // ""' <<< "$NODES_JSON" | sed 's/^NVIDIA-//')
  pciname=$(jq -r --arg n "$n" '[.items[] | select(.status.nodeName==$n and (.status.description|test("NVIDIA")))
            | (try (.status.description | capture("\\[(?<m>[^\\]]+)\\]").m) catch "NVIDIA")] | unique | join(",")' <<< "$PCI")
  kdrv=$(jq -r --arg n "$n" '[.items[] | select(.status.nodeName==$n and (.status.description|test("NVIDIA"))) | (.status.kernelDriverInUse // "none")] | unique | join(",")' <<< "$PCI")
  dver=$(jq -r --arg n "$n" '.items[] | select(.metadata.name==$n) | .metadata.labels["nvidia.com/cuda.driver-version.full"] // ""' <<< "$NODES_JSON")
  alloc=$(jq -r --arg n "$n" '.items[] | select(.metadata.name==$n) | .status.allocatable["nvidia.com/gpu"] // "0"' <<< "$NODES_JSON")

  nfd=$(st "$n" '^gpu-operator-node-feature-discovery-worker-')
  roles=""
  [ "$(st "$n" '^gpu-operator-[0-9a-f]+-[a-z0-9]+$')" = Running ]           && roles+="controller "
  [ "$(st "$n" '^gpu-operator-node-feature-discovery-master-')" = Running ] && roles+="nfd-master "
  [ "$(st "$n" '^gpu-operator-node-feature-discovery-gc-')" = Running ]     && roles+="nfd-gc"
  roles=${roles% }; roles=${roles:--}

  if [ "$ngpu" -eq 0 ]; then
    NOGPU=$((NOGPU+1))
    ROWS+=("none|$n|-|-|-|-|-|-|-|no GPU|$nfd|-|$roles")
    continue
  fi

  gpu=${label:-${pciname:-NVIDIA}}; gpu=${gpu%% /*}
  if [ "$kdrv" = nvidia ] && [ -n "$dver" ]; then drv=$dver; else drv=$kdrv; fi
  val=$(st "$n" '^nvidia-operator-validator-')
  dev=$(st "$n" '^nvidia-device-plugin-daemonset-')
  gfd=$(st "$n" '^gpu-feature-discovery-')
  dcgm=$(st "$n" '^nvidia-dcgm-exporter-')
  cuda=$(st "$n" '^nvidia-cuda-validator-')

  # GOOD: everything running and GPU schedulable
  # OK:   GPU schedulable but a non-critical part is down, or components still starting (no hard errors)
  # FAIL: GPU not schedulable and something is broken
  if [ "${alloc:-0}" -ge 1 ] && [ "$(cls "$dev")" = good ] && [ "$(cls "$val")" = good ] \
     && [ "$(cls "$gfd")" = good ] && [ "$(cls "$dcgm")" = good ] && [ "$(cls "$drv")" = good ]; then
    status=GOOD; GOOD=$((GOOD+1))
  elif { [ "${alloc:-0}" -ge 1 ] && [ "$(cls "$dev")" = good ]; } || \
       { [ "$(cls "$drv")" = good ] && ! printf '%s\n' "$val" "$dev" "$gfd" "$dcgm" | grep -qvE '^(Running|Completed|Init|Starting|Pending|PodInitializing|ContainerCreating)$'; }; then
    status=OK; OKC=$((OKC+1))
  else
    status=FAIL; FAIL=$((FAIL+1))
  fi
  ROWS+=("gpu|$n|$gpu|$drv|$val|$dev|$gfd|$dcgm|$alloc|$status|$nfd|$cuda|$roles")
done
TOTAL=$((GOOD+OKC+FAIL))

# ---- rendering --------------------------------------------------------------
if [ "$MODE" = term ]; then
  C_good=$'\e[32m'; C_warn=$'\e[33m'; C_bad=$'\e[31m'; C_none=''; BOLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  C_good=''; C_warn=''; C_bad=''; C_none=''; BOLD=''; DIM=''; RST=''
fi
statcls() { case $1 in GOOD) echo good ;; OK) echo warn ;; FAIL) echo bad ;; *) echo none ;; esac; }
gpucls()  { [ "$1" -ge 1 ] 2>/dev/null && echo good || echo bad; }

if [ "$MODE" = html ]; then
  css_good='color:#116329;background:#dafbe1'; css_warn='color:#7d4e00;background:#fff8c5'
  css_bad='color:#a40e26;background:#ffebe9';   css_none='color:#57606a'
  td() { local c="css_$2"; printf '<td style="padding:4px 10px;border-bottom:1px solid #d0d7de;%s%s">%s</td>' "${!c}" "${3:-}" "$1"; }
  cpc=css_bad; [ "$CPSTATE" = ready ] && cpc=css_good
  echo '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">'
  echo "<p style=\"margin:0 0 6px\"><b>Denovo PCE &ndash; GPU Operator status</b> &middot; $NOW</p>"
  echo "<p style=\"margin:0 0 10px\">Operator <b>$OPVER</b> &middot; ClusterPolicy <span style=\"${!cpc}\">$CPSTATE</span> &middot; GPU nodes: <span style=\"$css_good\">&nbsp;$GOOD GOOD&nbsp;</span> <span style=\"$css_warn\">&nbsp;$OKC OK&nbsp;</span> <span style=\"$css_bad\">&nbsp;$FAIL FAIL&nbsp;</span> of $TOTAL</p>"
  echo '<table style="border-collapse:collapse;font-family:Consolas,Menlo,monospace;font-size:13px">'
  hdr="Node GPU Driver Validator Device&nbsp;plugin Feature&nbsp;discovery DCGM GPUs Status"
  [ $VERBOSE = 1 ] && hdr="$hdr NFD CUDA&nbsp;validator Operator&nbsp;roles"
  printf '<tr>'; for h in $hdr; do printf '<th style="text-align:left;padding:4px 10px;border-bottom:2px solid #8c959f">%s</th>' "$h"; done; echo '</tr>'
  for r in "${ROWS[@]}"; do
    IFS='|' read -r kind n gpu drv val dev gfd dcgm alloc status nfd cuda roles <<< "$r"
    printf '<tr>'
    if [ "$kind" = none ]; then
      for v in "$n" - - - - - - - "no GPU"; do td "$v" none; done
      [ $VERBOSE = 1 ] && { td "$nfd" "$(cls "$nfd")"; td - none; td "$roles" none; }
    else
      td "$n" none ";font-weight:bold"; td "$gpu" none
      td "$drv" "$(cls "$drv")"; td "$val" "$(cls "$val")"; td "$dev" "$(cls "$dev")"
      td "$gfd" "$(cls "$gfd")"; td "$dcgm" "$(cls "$dcgm")"; td "$alloc" "$(gpucls "$alloc")"
      td "$status" "$(statcls "$status")" ";font-weight:bold"
      [ $VERBOSE = 1 ] && { td "$nfd" "$(cls "$nfd")"; [ "$cuda" = - ] && td - none || td "$cuda" "$(cls "$cuda")"; td "$roles" none; }
    fi
    echo '</tr>'
  done
  echo '</table>'
  printf '<p style="margin:10px 0 4px">DaemonSets (ready/desired): '
  while read -r name d rdy; do
    [ -z "$name" ] || [ "${d:-0}" = 0 ] && continue
    case $name in *node-feature-discovery*) continue ;; esac
    c=css_good; [ "$rdy" != "$d" ] && c=css_warn; [ "${rdy:-0}" = 0 ] && c=css_bad
    printf '<span style="%s">&nbsp;%s %s/%s&nbsp;</span> ' "${!c}" "${name#nvidia-}" "$rdy" "$d"
  done <<< "$DS"
  echo '</p>'
  echo "<p style=\"margin:4px 0;color:#57606a;font-size:12px\"><b>GOOD</b> = GPU schedulable, all components running &middot; <b>OK</b> = needs attention (starting up, or a non-critical component down) &middot; <b>FAIL</b> = GPU not usable</p>"
  echo '</div>'
else
  pad() { printf "%-${2}s" "$1"; }
  cell() { local c="C_$3"; printf '%s%s%s ' "${!c}" "$(pad "$1" "$2")" "$RST"; }
  cpc=C_bad; [ "$CPSTATE" = ready ] && cpc=C_good
  echo "${BOLD}Denovo PCE - GPU Operator status${RST}   $NOW"
  echo "Operator $OPVER | ClusterPolicy ${!cpc}$CPSTATE${RST} | GPU nodes: ${C_good}$GOOD GOOD${RST}, ${C_warn}$OKC OK${RST}, ${C_bad}$FAIL FAIL${RST} of $TOTAL"
  echo
  W=(8 16 10 10 13 17 10 4 7)
  H=(NODE GPU DRIVER VALIDATOR DEVICE-PLUGIN FEATURE-DISCOVERY DCGM GPUS STATUS)
  line="${BOLD}"; for i in "${!H[@]}"; do line+="$(pad "${H[$i]}" "${W[$i]}") "; done
  [ $VERBOSE = 1 ] && line+="$(pad NFD 9) $(pad CUDA-VAL 10) ROLES"
  echo "$line${RST}"
  for r in "${ROWS[@]}"; do
    IFS='|' read -r kind n gpu drv val dev gfd dcgm alloc status nfd cuda roles <<< "$r"
    if [ "$kind" = none ]; then
      line="${C_none}"; vals=("$n" - - - - - - - "no GPU")
      for i in "${!vals[@]}"; do line+="$(pad "${vals[$i]}" "${W[$i]}") "; done
      [ $VERBOSE = 1 ] && line+="$(pad "$nfd" 9) $(pad - 10) $roles"
      echo "$line${RST}"
    else
      line="$(cell "$n" 8 none)$(cell "$gpu" 16 none)$(cell "$drv" 10 "$(cls "$drv")")$(cell "$val" 10 "$(cls "$val")")"
      line+="$(cell "$dev" 13 "$(cls "$dev")")$(cell "$gfd" 17 "$(cls "$gfd")")$(cell "$dcgm" 10 "$(cls "$dcgm")")"
      line+="$(cell "$alloc" 4 "$(gpucls "$alloc")")${BOLD}$(cell "$status" 7 "$(statcls "$status")")"
      if [ $VERBOSE = 1 ]; then
        cc=none; [ "$cuda" != - ] && cc=$(cls "$cuda")
        line+="$(cell "$nfd" 9 "$(cls "$nfd")")$(cell "$cuda" 10 "$cc")$roles"
      fi
      echo "$line"
    fi
  done
  echo
  printf 'DaemonSets (ready/desired): '
  while read -r name d rdy; do
    [ -z "$name" ] || [ "${d:-0}" = 0 ] && continue
    case $name in *node-feature-discovery*) continue ;; esac
    c=C_good; [ "$rdy" != "$d" ] && c=C_warn; [ "${rdy:-0}" = 0 ] && c=C_bad
    printf '%s%s %s/%s%s  ' "${!c}" "${name#nvidia-}" "$rdy" "$d" "$RST"
  done <<< "$DS"
  echo
  echo "${DIM}GOOD = GPU schedulable, all components running | OK = needs attention (starting, or non-critical component down) | FAIL = GPU not usable${RST}"
fi

exit "$FAIL"
