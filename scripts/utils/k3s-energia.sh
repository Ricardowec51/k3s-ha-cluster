#!/usr/bin/env bash
# k3s-energia — apagado y arranque ordenado de la infraestructura doméstica
# (cluster K3s EMPRENDEDORES.LTD + hosts Proxmox + TrueNAS).
#
# Uso:
#   k3s-energia estado
#   k3s-energia apagar   [--solo-cluster] [--si] [--dry-run]
#   k3s-energia arrancar [--dry-run]
#   k3s-energia preparar-host <ip>   (host Proxmox nuevo: espera-TrueNAS + WOL persistente)
#
#   --solo-cluster  apaga solo las VMs del cluster; deja encendidos los hosts Proxmox,
#                   sus otras VMs y TrueNAS.
#   --si            no pide confirmación.
#   --dry-run       muestra lo que haría sin cambiar nada.
#
# Orden de apagado:  hibernar Postgres (CNPG) → workers → masters → otras VMs/CTs
#                    → hosts Proxmox → TrueNAS (al final, cuando nadie lo usa).
# Orden de arranque: TrueNAS → hosts Proxmox (WOL) → quórum PVE + storage TRUENAS
#                    → masters → workers → otras VMs → reparar CSI (controladores
#                    + leases viejos) → limpiar pods trabados → despertar Postgres
#                    → reiniciar CrashLoop → verificar servicios.
# Runbook y postmortem del corte de luz del 2026-10-17: docs/energia-y-arranque.md
# en el repo k3s-ha-cluster (este archivo: scripts/utils/k3s-energia.sh; copia
# instalada en ~/bin/k3s-energia del Mac mini M4 — mantener ambas iguales).

set -uo pipefail

# ---------------------------------------------------------------- configuración
# host proxmox: nombre ip mac
PVE_HOSTS="DELL:192.168.1.7:6c:1f:f7:56:f3:2b msa:192.168.1.143:58:47:ca:7c:23:79 msn2:192.168.1.86:58:47:ca:7c:6b:cc"
TRUENAS_IP=192.168.1.100
# WOL solo funciona por el puerto integrado I219-V (enp0s31f6): la NIC de la LAN
# (enp2s0f1, 10G SFP+ 82599ES) no soporta Wake-on-LAN. Ese puerto necesita cable a la LAN.
TRUENAS_MACS="1c:1b:0d:0b:ac:a1 98:b7:85:23:42:03"
# vmid@ip_host
MASTERS="3001@192.168.1.7 3002@192.168.1.143 3003@192.168.1.86"
WORKERS="3006@192.168.1.7 3005@192.168.1.143 3007@192.168.1.86"
MASTER_IPS="192.168.1.21 192.168.1.22 192.168.1.23"
CSI_NS=democratic-csi
NODOS_ESPERADOS=6

SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
LOG_DIR="$HOME/Library/Logs/k3s-energia"
DRY=0; SI=0; SOLO_CLUSTER=0

# ---------------------------------------------------------------- utilidades
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
paso() { echo; echo "${c_b}==> $*${c_0}"; }
ok()   { echo "  ${c_ok}✔${c_0} $*"; }
warn() { echo "  ${c_warn}!${c_0} $*"; }
err()  { echo "  ${c_err}✘${c_0} $*"; }
run()  { if [ $DRY = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

vivo()   { ping -c1 -t2 "$1" >/dev/null 2>&1; }
puerto() { nc -z -G3 "$1" "$2" >/dev/null 2>&1; }
pve()    { local ip=$1; shift; $SSH root@"$ip" "$@"; }

# espera <segundos> <descripción> <comando...>  — reintenta cada 10 s
espera() {
  local max=$1 desc=$2; shift 2
  local t=0
  until eval "$@"; do
    if [ $t -ge "$max" ]; then err "timeout (${max}s): $desc"; return 1; fi
    [ $((t % 60)) = 0 ] && echo "  … esperando: $desc (${t}s)"
    sleep 10; t=$((t + 10))
  done
  ok "$desc"
}

wol() {  # wol <mac> — magic packet por broadcast UDP 9
  [ $DRY = 1 ] && { echo "  [dry-run] WOL $1"; return; }
  python3 - "$1" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(':', '').zfill(12))
pkt = b'\xff' * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    s.sendto(pkt, ('192.168.1.255', 9))
PY
}

KC=""
api() {  # deja en $KC un kubectl apuntando a un master que responda
  local ip
  for ip in $MASTER_IPS; do
    if puerto "$ip" 6443; then KC="kubectl --request-timeout=20s --server=https://$ip:6443"; return 0; fi
  done
  KC=""; return 1
}
kc() { $KC "$@"; }

nodos_ready()   { kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' '; }
masters_ready() { kc get nodes --no-headers 2>/dev/null | awk '/master/ && $2=="Ready"' | wc -l | tr -d ' '; }
quorum_ok()     { pve 192.168.1.7 "pvecm status 2>/dev/null" | grep -q 'Quorate: *Yes'; }
storage_ok()    { pve "$1" "pvesm status 2>/dev/null" | awk '$1=="TRUENAS"{print $3}' | grep -q active; }
csi_nodos_ok()  { [ -z "$(kc -n $CSI_NS get pods --no-headers 2>/dev/null | awk '/-node-/{split($2,a,"/"); if (a[1]!=a[2]) print}')" ]; }
pg_sano() {     # pg_sano <ns> <cluster>
  local r s
  r=$(kc -n "$1" get cluster.postgresql.cnpg.io "$2" -o jsonpath='{.status.readyInstances}' 2>/dev/null)
  s=$(kc -n "$1" get cluster.postgresql.cnpg.io "$2" -o jsonpath='{.spec.instances}' 2>/dev/null)
  [ -n "$r" ] && [ "$r" = "$s" ]
}
pg_sin_pods() { [ -z "$(kc -n "$1" get pods -l cnpg.io/cluster="$2" --no-headers 2>/dev/null)" ]; }

# script que corre en cada host proxmox para apagar todas sus VMs y CTs
REMOTO_APAGAR_INVITADOS='
for v in $(qm list | awk "NR>1 && \$3==\"running\" {print \$1}"); do qm shutdown $v --timeout 180 --forceStop 1 & done
for c in $(pct list | awk "NR>1 && \$2==\"running\" {print \$1}"); do pct shutdown $c --timeout 120 --forceStop 1 & done
wait'
# script remoto que lista VMs detenidas con onboot=1
REMOTO_ONBOOT_DETENIDAS='
for v in $(qm list | awk "NR>1 && \$3==\"stopped\" {print \$1}"); do qm config $v | grep -q "^onboot: 1" && echo $v; done'

vm_estado() { pve "$2" "qm status $1" 2>/dev/null | awk '{print $2}'; }

# apaga en paralelo una lista vmid@ip con timeout y forzado
apagar_vms() {
  local lista=$1 timeout=$2 item vmid ip
  for item in $lista; do
    vmid=${item%@*}; ip=${item#*@}
    if [ "$(vm_estado "$vmid" "$ip")" = running ]; then
      run "pve $ip 'qm shutdown $vmid --timeout $timeout --forceStop 1' >/dev/null 2>&1 &"
    fi
  done
  [ $DRY = 1 ] || wait
  for item in $lista; do
    vmid=${item%@*}; ip=${item#*@}
    [ $DRY = 1 ] && continue
    local st; st=$(vm_estado "$vmid" "$ip")
    [ "$st" = stopped ] && ok "VM $vmid apagada" || err "VM $vmid sigue en estado '$st'"
  done
}

arrancar_vms() {
  local lista=$1 item vmid ip
  for item in $lista; do
    vmid=${item%@*}; ip=${item#*@}
    if [ "$(vm_estado "$vmid" "$ip")" = running ]; then ok "VM $vmid ya estaba corriendo"
    else
      run "pve $ip 'qm start $vmid'" && ok "VM $vmid arrancada" || err "VM $vmid no arrancó"
    fi
  done
}

confirmar() {
  [ $SI = 1 ] || [ $DRY = 1 ] && return 0
  echo; printf "%s" "${c_warn}Escribe APAGAR para continuar: ${c_0}"
  local r; read -r r
  [ "$r" = APAGAR ] || { echo "Cancelado."; exit 1; }
}

# ---------------------------------------------------------------- estado
cmd_estado() {
  paso "Equipos"
  vivo $TRUENAS_IP && ok "TrueNAS $TRUENAS_IP" || err "TrueNAS $TRUENAS_IP no responde"
  local h n ip
  for h in $PVE_HOSTS; do
    n=${h%%:*}; ip=$(echo "$h" | cut -d: -f2)
    if vivo "$ip"; then
      ok "$n $ip — $(pve "$ip" "qm list | awk 'NR>1 && \$3==\"running\"' | wc -l" 2>/dev/null | tr -d ' ') VMs corriendo"
    else err "$n $ip no responde"; fi
  done
  if vivo 192.168.1.7; then
    quorum_ok && ok "Quórum Proxmox" || warn "Proxmox sin quórum"
  fi

  paso "Cluster K3s"
  if ! api; then err "API de K3s no responde en ningún master"; return; fi
  kc get nodes --no-headers | awk '{printf "  %-15s %s\n",$1,$2}'
  kc get cluster.postgresql.cnpg.io -A --no-headers 2>/dev/null | awk '{printf "  Postgres %s/%s: %s/%s listas — %s\n",$1,$2,$5,$4,substr($0,index($0,$6))}'
  local malos; malos=$(kc get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4!="Completed" && ($4!="Running" || a[1]!=a[2])) print "  "$1"/"$2" "$3" "$4}')
  [ -z "$malos" ] && ok "Todos los pods sanos" || { warn "Pods con problemas:"; echo "$malos"; }

  paso "Servicios (LoadBalancer)"
  kc get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer"{print $1,$2,$5,$6}' |
  while read -r ns n ip ports; do
    local p; p=$(echo "$ports" | cut -d: -f1 | cut -d, -f1)
    puerto "$ip" "$p" && ok "$ns/$n $ip:$p" || err "$ns/$n $ip:$p"
  done
}

# ---------------------------------------------------------------- apagar
cmd_apagar() {
  paso "Apagado ordenado $( [ $SOLO_CLUSTER = 1 ] && echo '(solo cluster)' || echo '(TODO, incluido TrueNAS)')"
  cmd_estado
  confirmar

  paso "1/6 Hibernando Postgres (CNPG)"
  if api; then
    kc get cluster.postgresql.cnpg.io -A --no-headers 2>/dev/null | while read -r ns name _; do
      run "kc -n $ns annotate cluster.postgresql.cnpg.io $name cnpg.io/hibernation=on --overwrite >/dev/null"
      [ $DRY = 1 ] || espera 300 "Postgres $ns/$name hibernado" "pg_sin_pods $ns $name"
    done
  else warn "API no responde; se omite hibernación de Postgres"; fi

  paso "2/6 Apagando workers"
  apagar_vms "$WORKERS" 180

  paso "3/6 Apagando masters"
  apagar_vms "$MASTERS" 120

  if [ $SOLO_CLUSTER = 1 ]; then paso "Listo (solo cluster). Hosts y TrueNAS siguen encendidos."; return; fi

  paso "4/6 Apagando el resto de VMs y contenedores en los hosts"
  local h ip
  for h in $PVE_HOSTS; do
    ip=$(echo "$h" | cut -d: -f2)
    vivo "$ip" || continue
    if [ $DRY = 1 ]; then echo "  [dry-run] ${h%%:*}: apagar todas las VMs y CTs"
    else echo "$REMOTO_APAGAR_INVITADOS" | pve "$ip" bash -s >/dev/null 2>&1 & fi
  done
  [ $DRY = 1 ] || wait
  ok "VMs/CTs de los hosts apagadas"

  paso "5/6 Apagando hosts Proxmox"
  for h in $PVE_HOSTS; do
    ip=$(echo "$h" | cut -d: -f2)
    vivo "$ip" && run "pve $ip 'nohup systemctl poweroff >/dev/null 2>&1 &' || true"
  done
  if [ $DRY = 0 ]; then
    for h in $PVE_HOSTS; do
      ip=$(echo "$h" | cut -d: -f2)
      espera 300 "${h%%:*} apagado" "! vivo $ip"
    done
  fi

  paso "6/6 Apagando TrueNAS"
  if vivo $TRUENAS_IP; then
    run "$SSH root@$TRUENAS_IP \"midclt call system.shutdown 'k3s-energia: apagado ordenado'\" >/dev/null 2>&1 || $SSH root@$TRUENAS_IP 'shutdown -h now'"
    [ $DRY = 1 ] || espera 600 "TrueNAS apagado" "! vivo $TRUENAS_IP"
  fi
  paso "Apagado completo."
}

# ---------------------------------------------------------------- arrancar
cmd_arrancar() {
  paso "1/10 TrueNAS (primero, por WOL)"
  if ! vivo $TRUENAS_IP; then
    for m in $TRUENAS_MACS; do wol "$m"; done
    echo "  WOL enviado a TrueNAS. Si no sube en ~3 min, revisa el cable del puerto integrado o enciéndelo a mano."
  fi
  espera 1200 "TrueNAS sirviendo NFS e iSCSI" "puerto $TRUENAS_IP 2049 && puerto $TRUENAS_IP 3260" || exit 1

  # Los hosts se despiertan recién ahora; además cada host tiene un ExecStartPre en
  # pve-guests (/usr/local/sbin/esperar-truenas) que retiene las VMs hasta ver TrueNAS.
  paso "2/10 Hosts Proxmox (WOL)"
  local h n ip mac
  for h in $PVE_HOSTS; do
    n=${h%%:*}; ip=$(echo "$h" | cut -d: -f2); mac=$(echo "$h" | cut -d: -f3-)
    vivo "$ip" || { wol "$mac"; echo "  WOL enviado a $n"; }
  done
  for h in $PVE_HOSTS; do
    ip=$(echo "$h" | cut -d: -f2)
    espera 900 "${h%%:*} accesible por SSH" "puerto $ip 22" || warn "Enciende ${h%%:*} a mano y vuelve a correr 'k3s-energia arrancar'"
  done

  paso "3/10 Quórum Proxmox y storage TRUENAS"
  espera 300 "Proxmox con quórum" "quorum_ok"
  for h in $PVE_HOSTS; do
    ip=$(echo "$h" | cut -d: -f2)
    espera 300 "storage TRUENAS activo en ${h%%:*}" "storage_ok $ip"
  done

  paso "4/10 Masters"
  arrancar_vms "$MASTERS"
  [ $DRY = 1 ] || espera 600 "API de K3s responde" "api"
  [ $DRY = 1 ] || espera 600 "3 masters Ready" "[ \"\$(masters_ready)\" -ge 3 ]"

  paso "5/10 Workers"
  arrancar_vms "$WORKERS"
  [ $DRY = 1 ] || espera 900 "$NODOS_ESPERADOS nodos Ready" "[ \"\$(nodos_ready)\" -ge $NODOS_ESPERADOS ]"

  paso "6/10 Resto de VMs con arranque automático"
  for h in $PVE_HOSTS; do
    ip=$(echo "$h" | cut -d: -f2)
    for v in $(echo "$REMOTO_ONBOOT_DETENIDAS" | pve "$ip" bash -s 2>/dev/null); do
      if [ $DRY = 1 ]; then echo "  [dry-run] ${h%%:*}: qm start $v"; continue; fi
      pve "$ip" "qm start $v" >/dev/null 2>&1 && ok "${h%%:*}: VM $v arrancada" || warn "${h%%:*}: VM $v no arrancó (¿storage caído?)"
    done
  done

  api || { err "API no responde"; exit 1; }

  paso "7/10 Driver de almacenamiento (democratic-csi)"
  # Los pods de nodo CSI de antes del apagado pueden quedar en Unknown/Terminating y el
  # DaemonSet no los reemplaza hasta borrarlos (pasó el 2026-10-26 en worker-03): sin
  # ellos el nodo no monta volúmenes. Se borran antes de esperar.
  kc -n $CSI_NS get pods --no-headers 2>/dev/null | awk '$3=="Terminating" || $3=="Unknown" {print $1}' |
  while read -r p; do
    run "kc -n $CSI_NS delete pod $p --grace-period=0 --force >/dev/null 2>&1" && warn "borrado forzado: $CSI_NS/$p"
  done
  [ $DRY = 1 ] || espera 600 "pods de nodo CSI listos" "csi_nodos_ok"
  # Los controladores pueden quedar con el external-attacher colgado si arrancaron antes
  # que el driver (pasó el 2026-10-18): se reinician siempre, no tienen estado.
  for d in $(kc -n $CSI_NS get deploy -o name 2>/dev/null); do
    run "kc -n $CSI_NS rollout restart $d >/dev/null" && run "kc -n $CSI_NS rollout status $d --timeout=300s >/dev/null" && ok "$d reiniciado"
  done
  # Leases de líder cuyo dueño es un pod que ya no existe bloquean al controlador nuevo.
  local pods; pods=" $(kc -n $CSI_NS get pods -o jsonpath='{.items[*].metadata.name}') "
  kc -n $CSI_NS get lease -o jsonpath='{range .items[*]}{.metadata.name} {.spec.holderIdentity}{"\n"}{end}' 2>/dev/null |
  while read -r lease holder; do
    case "$holder" in *controller*) ;; *) continue ;; esac   # los de id numérico no son nombres de pod
    case "$pods" in *" $holder "*) ;; *) run "kc -n $CSI_NS delete lease $lease >/dev/null" && warn "lease viejo borrado: $lease ($holder)";; esac
  done

  paso "8/10 Pods trabados de antes del apagado"
  kc get pods -A --no-headers 2>/dev/null | awk '$4=="Terminating" || $4=="Unknown" {print $1, $2}' |
  while read -r ns p; do
    run "kc -n $ns delete pod $p --grace-period=0 --force >/dev/null 2>&1" && warn "borrado forzado: $ns/$p"
  done

  paso "9/10 Despertando Postgres (CNPG)"
  kc get cluster.postgresql.cnpg.io -A --no-headers 2>/dev/null | while read -r ns name _; do
    run "kc -n $ns annotate cluster.postgresql.cnpg.io $name cnpg.io/hibernation=off --overwrite >/dev/null"
    [ $DRY = 1 ] || espera 900 "Postgres $ns/$name sano" "pg_sano $ns $name"
  done
  [ $DRY = 1 ] || { local va; va=$(kc get volumeattachments -o jsonpath='{range .items[?(@.status.attached==false)]}{.spec.source.persistentVolumeName} {.spec.nodeName}{"\n"}{end}' 2>/dev/null)
    [ -z "$va" ] && ok "Todos los volúmenes conectados" || { warn "Volúmenes sin conectar:"; echo "$va" | sed 's/^/    /'; }; }

  paso "10/10 Apps que fallaron mientras la base de datos estaba caída"
  kc get pods -A --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff" || $4=="Error" {print $1, $2}' |
  while read -r ns p; do
    local owner; owner=$(kc -n "$ns" get pod "$p" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
    local dep; dep=$(kc -n "$ns" get rs "$owner" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
    [ -n "$dep" ] && run "kc -n $ns rollout restart deploy/$dep >/dev/null" && warn "reiniciado: $ns/$dep"
  done

  paso "Resultado"
  cmd_estado
}

# ---------------------------------------------------------------- preparar-host
# Deja un host Proxmox (nuevo o existente) listo para este esquema:
#  - pve-guests espera a TrueNAS antes de arrancar VMs con onboot=1
#  - WOL activo en la NIC del bridge vmbr0, persistente entre reinicios
cmd_preparar_host() {
  local ip=${1:-}
  [ -n "$ip" ] || { echo "Uso: k3s-energia preparar-host <ip-del-host-proxmox>"; exit 2; }
  paso "Preparando host Proxmox $ip"
  [ $DRY = 1 ] && { echo "  [dry-run] instalar esperar-truenas + WOL persistente en $ip"; return; }
  pve "$ip" 'bash -s' <<'EOF'
cat > /usr/local/sbin/esperar-truenas <<'S'
#!/bin/sh
# Espera a que el storage TRUENAS esté activo antes de que pve-guests arranque las VMs
# con onboot=1 (tras un corte de luz los workers K3s fallaban con
# "storage 'TRUENAS' is not online"). Si TrueNAS no aparece en 15 min, sigue igual
# para que al menos arranquen las VMs con disco local. Instalado por k3s-energia (Mac M4).
MAX=900; t=0
while [ "$t" -lt "$MAX" ]; do
  if pvesm status 2>/dev/null | awk '$1=="TRUENAS"{print $3}' | grep -q active; then
    echo "TrueNAS disponible tras ${t}s"; exit 0
  fi
  sleep 10; t=$((t + 10))
done
echo "TrueNAS no disponible tras ${MAX}s; se arrancan las VMs de todas formas"
exit 0
S
chmod 755 /usr/local/sbin/esperar-truenas
mkdir -p /etc/systemd/system/pve-guests.service.d
cat > /etc/systemd/system/pve-guests.service.d/esperar-truenas.conf <<'S'
# Las VMs arrancan después de TrueNAS (ver /usr/local/sbin/esperar-truenas)
[Service]
ExecStartPre=-/usr/local/sbin/esperar-truenas
S
p=$(ls /sys/class/net/vmbr0/brif | grep -vE 'tap|fwpr|fwln|veth' | head -1)
cat > /etc/systemd/system/wol-vmbr0.service <<S
[Unit]
Description=Wake-on-LAN en $p (k3s-energia)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $p wol g
[Install]
WantedBy=multi-user.target
S
systemctl daemon-reload
systemctl enable --now wol-vmbr0.service >/dev/null 2>&1
echo "  $(hostname): hook=$(systemctl show pve-guests -p ExecStartPre | grep -c esperar-truenas) nic=$p mac=$(cat /sys/class/net/$p/address) $(ethtool $p | grep -E '^\s+Wake-on:' | tr -d '\t')"
EOF
  warn "Recuerda: agregar el host a PVE_HOSTS en este script (nombre:ip:mac), y en la BIOS activar Wake-on-LAN y desactivar ErP/Deep Sleep."
}

# ---------------------------------------------------------------- main
CMD=${1:-}; shift || true
ARG=""
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --si) SI=1 ;;
    --solo-cluster) SOLO_CLUSTER=1 ;;
    -*) echo "Opción desconocida: $a"; exit 2 ;;
    *) ARG=$a ;;
  esac
done

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-${CMD:-ayuda}.log"

case $CMD in
  estado)   cmd_estado ;;
  apagar)   cmd_apagar   2>&1 | tee "$LOG" ;;
  arrancar) cmd_arrancar 2>&1 | tee "$LOG" ;;
  preparar-host) cmd_preparar_host "$ARG" ;;
  *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
