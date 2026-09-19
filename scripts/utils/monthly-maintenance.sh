#!/usr/bin/env bash
# Mantenimiento mensual de hosts Proxmox sin perder quórum de etcd ni servicio.
#
# Uso:
#   monthly-maintenance.sh status
#   monthly-maintenance.sh prepare <host> [--dry-run]
#   monthly-maintenance.sh restore <host>
#
#   status   : distribución VM->host, nodos, etcd, quórum Proxmox y pods con problemas.
#   prepare  : chequeos previos + switchover de CNPG si el primary está en ese host
#              + cordon/drain del worker de ese host. --dry-run solo chequea y avisa.
#   restore  : espera a que las VMs del host vuelvan, hace uncordon y verifica etcd/pods.
#
# Flujo por host (UN host a la vez):
#   1) prepare <host>   2) actualizar/reiniciar el host en Proxmox (manual)
#   3) restore <host>   4) esperar SOAK_MIN minutos y repetir con el siguiente host.
#
# Notas:
#  - Con Proxmox en 3/4 votos (nuc10 fuera), al apagar UN host el cluster Proxmox pierde
#    quórum mientras esté abajo: las VMs siguen corriendo, pero no se puede iniciar ni
#    migrar nada hasta que el host vuelva. Por eso el quórum solo se exige en `prepare`.
#  - kubectl usa --server con fallback entre los masters: el kubeconfig apunta a master-01
#    y esa VM cae cuando se reinicia su host.
#  - FORCE=1 salta los chequeos previos (no recomendado).
set -uo pipefail

# --- Configuración (editar al reemplazar nuc10 o agregar hosts) ---------------------
HOSTS="DELL:192.168.1.7 msa:192.168.1.143 msn2:192.168.1.86"   # nombre Proxmox:IP
API_IPS="192.168.1.21 192.168.1.22 192.168.1.23"               # masters, para kubectl
SOAK_MIN="${SOAK_MIN:-15}"          # minutos que los OTROS hosts deben llevar encendidos
CNPG_NS="contactos"
CNPG_CLUSTER="postgres-contactos"
# vmid -> nodo K3s (VMIDs de las VMs del cluster)
vm_node() {
  case "$1" in
    3001) echo k3s-master-01 ;; 3002) echo k3s-master-02 ;; 3003) echo k3s-master-03 ;;
    3005) echo k3s-worker-02 ;; 3006) echo k3s-worker-03 ;; 3007) echo k3s-worker-04 ;;
  esac
}

# --- Utilidades ---------------------------------------------------------------------
info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

API=""
pick_api() {   # elige el primer master que responda
  local ip
  for ip in $API_IPS; do
    if kubectl --server="https://$ip:6443" --request-timeout=5s get --raw /readyz >/dev/null 2>&1; then
      API="$ip"; return 0
    fi
  done
  API=""; return 1
}
k() { kubectl --server="https://$API:6443" --request-timeout=30s "$@"; }

host_ip() { for e in $HOSTS; do [ "${e%%:*}" = "$1" ] && echo "${e##*:}"; done; }

pve() {        # corre un comando en el primer host Proxmox que responda
  for e in $HOSTS; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${e##*:}" "$@" 2>/dev/null && return 0
  done
  return 1
}

vm_hosts() {   # imprime "vmid host" para las VMs del cluster
  pve "pvesh get /cluster/resources --type vm --output-format json" | python3 -c '
import sys, json
for v in sorted(json.load(sys.stdin), key=lambda x: x["vmid"]):
    if 3001 <= v["vmid"] <= 3007:
        print(v["vmid"], v["node"])'
}

nodes_on_host() { vm_hosts | while read -r id h; do [ "$h" = "$1" ] && vm_node "$id"; done; }
workers_on_host() { nodes_on_host "$1" | grep worker; }
masters_on_host() { nodes_on_host "$1" | grep master; }

etcd_ok()   { k get --raw '/readyz?verbose' 2>/dev/null | grep -q '\[+\]etcd ok'; }
# Un nodo en cordon muestra "Ready,SchedulingDisabled": basta con que empiece por Ready.
not_ready() { k get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1}'; }
node_ready() { [ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
bad_pods()  { k get pods -A --no-headers 2>/dev/null | grep -Ev ' (Running|Completed) '; }

# --- status -------------------------------------------------------------------------
cmd_status() {
  pick_api || die "Ningún master responde (${API_IPS})"
  info "API vía $API"
  echo; echo "Distribución (host: nodos):"
  for e in $HOSTS; do
    h="${e%%:*}"; echo "  $h: $(nodes_on_host "$h" | tr '\n' ' ')"
  done
  echo; k get nodes --no-headers | awk '{print "  " $1, $2}'
  etcd_ok && ok "etcd ok" || warn "etcd NO está ok"
  pve "pvecm status" | grep -E 'Quorate|Total votes|Expected votes' | sed 's/^/  Proxmox: /'
  b=$(bad_pods); [ -z "$b" ] && ok "sin pods con problemas" || { warn "pods con problemas:"; echo "$b"; }
}

# --- prepare ------------------------------------------------------------------------
cnpg_switchover() {   # $1 = worker que se va a drenar
  local primary node replica t
  primary=$(k -n "$CNPG_NS" get clusters.postgresql.cnpg.io "$CNPG_CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null) || return 0
  [ -z "$primary" ] && return 0
  node=$(k -n "$CNPG_NS" get pod "$primary" -o jsonpath='{.spec.nodeName}')
  [ "$node" != "$1" ] && { ok "CNPG: el primary ($primary) no está en $1"; return 0; }
  replica=$(k -n "$CNPG_NS" get pod -l "cnpg.io/cluster=$CNPG_CLUSTER" -o name | sed 's#pod/##' | grep -v "^$primary$" | head -1)
  [ -z "$replica" ] && die "CNPG: no hay réplica a la cual promover"
  info "CNPG: switchover $primary -> $replica (el PDB del primary bloquearía el drain)"
  k -n "$CNPG_NS" patch clusters.postgresql.cnpg.io "$CNPG_CLUSTER" --subresource=status --type=merge \
    -p "{\"status\":{\"targetPrimary\":\"$replica\"}}" >/dev/null || die "CNPG: no se pudo iniciar el switchover"
  for t in $(seq 1 36); do
    sleep 5
    if [ "$(k -n "$CNPG_NS" get clusters.postgresql.cnpg.io "$CNPG_CLUSTER" -o jsonpath='{.status.currentPrimary}')" = "$replica" ] &&
       k -n "$CNPG_NS" get clusters.postgresql.cnpg.io "$CNPG_CLUSTER" -o jsonpath='{.status.phase}' | grep -q 'healthy'; then
      ok "CNPG: nuevo primary $replica, cluster sano"; return 0
    fi
  done
  die "CNPG: el switchover no completó en 3 min; revisar antes de continuar"
}

cmd_prepare() {
  local host="$1" dry="${2:-}" ip e h up nm
  ip=$(host_ip "$host"); [ -n "$ip" ] || die "Host desconocido: $host (${HOSTS})"
  pick_api || die "Ningún master responde"
  info "Preparando $host ($ip) — API vía $API"

  masters=$(masters_on_host "$host"); workers=$(workers_on_host "$host")
  info "VMs K3s en $host: $(echo $masters $workers)"
  [ "$(echo "$masters" | grep -c master)" -gt 1 ] && [ -z "${FORCE:-}" ] &&
    die "$host aloja más de un master: apagarlo rompe el quórum de etcd"

  if [ -z "${FORCE:-}" ]; then
    nr=$(not_ready); [ -z "$nr" ] || die "Nodos no Ready: $nr"
    etcd_ok || die "etcd no está ok"
    [ -z "$(bad_pods)" ] || { warn "Hay pods con problemas:"; bad_pods; die "Resolver antes de continuar (o FORCE=1)"; }
    pve "pvecm status" | grep -q 'Quorate: *Yes' || die "Proxmox sin quórum"
    for e in $HOSTS; do
      h="${e%%:*}"; [ "$h" = "$host" ] && continue
      up=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${e##*:}" 'cut -d. -f1 /proc/uptime') || die "No se pudo consultar $h"
      [ "$up" -ge $((SOAK_MIN * 60)) ] || die "$h se reinició hace $((up / 60)) min (< ${SOAK_MIN}); esperar"
    done
    ok "Chequeos previos OK (nodos Ready, etcd ok, sin pods caídos, Proxmox con quórum, otros hosts estables)"
  fi

  for w in $workers; do
    info "Pods no-DaemonSet en $w (se reprograman; los de 1 réplica tendrán un corte breve):"
    k get pods -A -o json --field-selector "spec.nodeName=$w,status.phase=Running" | python3 -c '
import sys, json
skip = ("kube-system", "metallb-system", "longhorn-system", "democratic-csi")
for p in json.load(sys.stdin)["items"]:
    owner = (p["metadata"].get("ownerReferences") or [{}])[0].get("kind")
    ns = p["metadata"]["namespace"]
    if owner != "DaemonSet" and ns not in skip:
        print("    %s/%s" % (ns, p["metadata"]["name"]))'
    [ "$dry" = "--dry-run" ] && { info "[dry-run] haría: switchover CNPG si aplica; cordon + drain de $w"; continue; }
    cnpg_switchover "$w"
    k cordon "$w" >/dev/null && ok "cordon $w"
    if ! k drain "$w" --ignore-daemonsets --delete-emptydir-data --timeout=300s; then
      warn "El drain de $w no terminó. Pods restantes / PDBs:"
      k get pods -A -o wide --no-headers --field-selector "spec.nodeName=$w" | grep -v DaemonSet | head
      k get pdb -A --no-headers
      die "$w queda en cordon. Resolver o continuar bajo tu criterio; luego usar restore."
    fi
    ok "drain $w completo"
  done
  [ "$dry" = "--dry-run" ] && { ok "dry-run terminado: no se cambió nada"; return 0; }
  echo
  ok "Listo para actualizar/reiniciar $host en Proxmox."
  info "Cuando las VMs hayan vuelto:  $0 restore $host"
}

# --- restore ------------------------------------------------------------------------
cmd_restore() {
  local host="$1" n t
  [ -n "$(host_ip "$host")" ] || die "Host desconocido: $host"
  nodes=$(nodes_on_host "$host"); [ -n "$nodes" ] || die "No se pudo resolver las VMs de $host (¿Proxmox sin quórum aún?)"
  info "Esperando (máx. 15 min) a que estén Ready: $(echo $nodes)"
  for t in $(seq 1 90); do
    if pick_api; then
      pend=""
      for n in $nodes; do node_ready "$n" || pend="$pend $n"; done
      [ -z "$pend" ] && break
    fi
    sleep 10
  done
  [ -z "${pend:-}" ] || die "Siguen sin estar Ready:${pend}. No hago uncordon."
  ok "Nodos de $host Ready"
  for n in $(workers_on_host "$host"); do k uncordon "$n" >/dev/null && ok "uncordon $n"; done
  for t in $(seq 1 30); do
    etcd_ok && [ -z "$(not_ready)" ] && break
    sleep 10
  done
  etcd_ok && [ -z "$(not_ready)" ] || die "etcd/nodos aún no estables; NO continuar con otro host"
  ok "etcd ok y todos los nodos Ready"
  for t in $(seq 1 30); do [ -z "$(bad_pods)" ] && break; sleep 10; done
  [ -z "$(bad_pods)" ] && ok "sin pods con problemas" || { warn "pods con problemas:"; bad_pods; }
  echo
  info "Esperar ${SOAK_MIN} min antes de tocar el siguiente host."
}

# --- main ---------------------------------------------------------------------------
case "${1:-}" in
  status)  cmd_status ;;
  prepare) [ -n "${2:-}" ] || die "Falta <host>"; cmd_prepare "$2" "${3:-}" ;;
  restore) [ -n "${2:-}" ] || die "Falta <host>"; cmd_restore "$2" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
