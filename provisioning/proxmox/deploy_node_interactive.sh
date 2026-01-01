#!/bin/bash

# =================================================================
#   PROXMOX K3S DEPLOYER - ULTIMATE EDITION v4.0
#   Diseñado para: Ricardowec51
# =================================================================

set -euo pipefail

# Colores y Estética
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
DEFAULT_PVE_IP="192.168.1.88"
DEFAULT_GATEWAY="192.168.1.1"
ANSIBLE_PLAYBOOK="/Volumes/Externo/ansible/deploy_single_node.yml"

# --- FUNCIONES DE INTELIGENCIA ---

is_numeric() { [[ "$1" =~ ^[0-9]+$ ]]; }

check_ip_ping() {
    local ip=$1
    echo -ne "  🔍 Verificando red para $ip... "
    if ping -c 1 -W 1 "$ip" > /dev/null 2>&1; then
        echo -e "${RED}[OCUPADA]${NC}"; return 1
    else
        echo -e "${GREEN}[LIBRE]${NC}"; return 0
    fi
}

get_pve_ticket() {
    local ticket
    ticket=$(curl -k -s -d "username=$2" -d "password=$3" "https://$1:8006/api2/json/access/ticket" | jq -r '.data.ticket' 2>/dev/null)
    echo "$ticket"
}

fetch_nodes() {
    curl -k -s -b "PVEAuthCookie=$2" "https://$1:8006/api2/json/nodes" | jq -r '.data[].node' 2>/dev/null | tr '\n' ' '
}

fetch_storages() {
    curl -k -s -b "PVEAuthCookie=$2" "https://$1:8006/api2/json/storage" | jq -r '.data[] | select(.active==1) | .storage' 2>/dev/null | tr '\n' ' '
}

check_vm_exists() {
    local status=$(curl -k -s -b "PVEAuthCookie=$4" "https://$1:8006/api2/json/nodes/$2/qemu/$3/status/current" | jq -r '.data.status' 2>/dev/null)
    [[ "$status" == "null" || -z "$status" ]] && return 1 || return 0
}

# --- INTERFAZ DE USUARIO ---

clear
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}         BIENVENIDO AL INSTALADOR INTELIGENTE DE K3S          ${NC}"
echo -e "${BLUE}================================================================${NC}"

# 1. ACCESO Y DESCUBRIMIENTO
echo -e "\n${YELLOW}>>> CONFIGURACIÓN DE ACCESO${NC}"
read -p "IP Proxmox API ([$DEFAULT_PVE_IP]): " PVE_IP; PVE_IP=${PVE_IP:-$DEFAULT_PVE_IP}
read -p "Usuario ([root@pam]): " PVE_USER; PVE_USER=${PVE_USER:-"root@pam"}
read -s -p "Contraseña: " PVE_PASS; echo ""

TICKET=$(get_pve_ticket "$PVE_IP" "$PVE_USER" "$PVE_PASS")
if [[ "$TICKET" == "null" || -z "$TICKET" ]]; then echo -e "${RED}Error: Credenciales inválidas.${NC}"; exit 1; fi

VALID_NODES=$(fetch_nodes "$PVE_IP" "$TICKET")
echo -e "Nodos detectados: ${CYAN}$VALID_NODES${NC}"

VALID_STORAGES=$(fetch_storages "$PVE_IP" "$TICKET")
while true; do
    echo -e "Storages Activos: ${CYAN}$VALID_STORAGES${NC}"
    read -p "Selecciona Storage destino ([NFS_SHARE]): " STORAGE
    STORAGE=${STORAGE:-"NFS_SHARE"}
    if [[ " $VALID_STORAGES " =~ " $STORAGE " ]]; then break; 
    else echo -e "${RED}Storage inválido.${NC}"; fi
done

# 2. GESTIÓN DE PLANTILLA
echo -e "\n${YELLOW}>>> GESTIÓN DE PLANTILLACloud-Init${NC}"
read -p "ID de Plantilla ([9000]): " TPL_ID; TPL_ID=${TPL_ID:-"9000"}

FOUND_TPL=0
TPL_NODE=""
for n in $VALID_NODES; do
    if check_vm_exists "$PVE_IP" "$n" "$TPL_ID" "$TICKET"; then FOUND_TPL=1; TPL_NODE=$n; break; fi
done

RECREAR="n"
if [[ $FOUND_TPL -eq 1 ]]; then
    echo -e "${GREEN}✅ Plantilla encontrada en $TPL_NODE.${NC}"
    read -p "¿Deseas re-crearla desde Ubuntu Cloud? (s/n): " RECREAR
else
    echo -e "${RED}❌ Plantilla no encontrada.${NC}"
    RECREAR="s"
fi

if [[ "$RECREAR" == "s" ]]; then
    read -p "¿En qué nodo construirla? (Sugerido: nuc10): " BUILD_NODE
    echo -e "${BLUE}Iniciando Bootstrap de Plantilla via SSH...${NC}"
    ssh -o StrictHostKeyChecking=no "root@$PVE_IP" << 'EOF'
        set -e
        wget -q --show-progress -O /tmp/noble.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
        qm destroy $TPL_ID 2>/dev/null || true
        qm create $TPL_ID --name "u24-tpl" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
        qm importdisk $TPL_ID /tmp/noble.img $STORAGE
        DISK_ID=$(pvesm list $STORAGE | grep "vm-$TPL_ID-disk" | awk '{print $1}' | head -n 1)
        qm set $TPL_ID --scsihw virtio-scsi-pci --scsi0 $DISK_ID --ide2 $STORAGE:cloudinit --boot order=scsi0 --agent 1
        qm template $TPL_ID
        rm /tmp/noble.img
EOF
    TPL_NODE=$BUILD_NODE
    echo -e "${GREEN}✅ Plantilla $TPL_ID lista.${NC}"
fi

# 3. HARDWARE DIFERENCIADO
echo -e "\n${YELLOW}>>> HARDWARE POR TIPO${NC}"
echo -e "${CYAN}[ MASTERS ]${NC}"
read -p "RAM (MB, [8192]): " M_RAM; M_RAM=${M_RAM:-8192}
read -p "Disco (ej. 100G): " M_DISK; M_DISK=${M_DISK:-"100G"}
echo -e "${CYAN}[ WORKERS ]${NC}"
read -p "RAM (MB, [16384]): " W_RAM; W_RAM=${W_RAM:-16384}
read -p "Disco (ej. 500G): " W_DISK; W_DISK=${W_DISK:-"500G"}

# 4. RECOLECCIÓN DE NODOS
collect_nodes() {
    local type=$1; local count=$2; local sug_id_start=$3; local sug_ip_start=$4
    local -n names=$5; local -n ids=$6; local -n ips=$7; local -n nodes=$8
    
    echo -e "\n${YELLOW}>>> CONFIGURACIÓN DE ${type}S${NC}"
    for ((i=0; i<count; i++)); do
        echo -e "\n--- ${type} $((i+1)) ---"
        names[$i]="k3s-${type,,}-$((i+1))"
        
        while true; do
            read -p "VM ID (Sugerido $((sug_id_start+i))): " ID; ID=${ID:-$((sug_id_start+i))}
            if is_numeric "$ID"; then 
                EXISTS=0
                for n in $VALID_NODES; do if check_vm_exists "$PVE_IP" "$n" "$ID" "$TICKET"; then EXISTS=1; break; fi; done
                [[ $EXISTS -eq 0 ]] && { ids[$i]=$ID; break; } || echo -e "${RED}ID ocupado.${NC}"
            else echo -e "${RED}Ingresa un número.${NC}"; fi
        done

        while true; do
            read -p "IP Estática (Sugerido 192.168.1.$((sug_ip_start+i))): " IP; IP=${IP:-"192.168.1.$((sug_ip_start+i))"}
            if check_ip_ping "$IP"; then ips[$i]=$IP; break;
            else read -p "¿Usar de todos modos? (s/n): " R; [[ "$R" == "s" ]] && { ips[$i]=$IP; break; }; fi
        done

        while true; do
            read -p "Nodo Destino (Opciones: $VALID_NODES): " T_NODE
            if [[ " $VALID_NODES " =~ " $T_NODE " ]]; then nodes[$i]=$T_NODE; break;
            else echo -e "${RED}Nodo inválido.${NC}"; fi
        done
    done
}

# Ejecutar recolección
M_NAMES=(); M_IDS=(); M_IPS=(); M_NODES=()
read -p "\n¿Cuántos Masters? ([3]): " NC_M; NC_M=${NC_M:-3}
collect_nodes "Master" "$NC_M" 2001 21 M_NAMES M_IDS M_IPS M_NODES

W_NAMES=(); W_IDS=(); W_IPS=(); W_NODES=()
read -p "\n¿Cuántos Workers? ([3]): " NC_W; NC_W=${NC_W:-3}
collect_nodes "Worker" "$NC_W" 2101 31 W_NAMES W_IDS W_IPS W_NODES

# 5. DESPLIEGUE MASIVO
clear
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}           INICIANDO DESPLIEGUE DINÁMICO VALIDADO               ${NC}"
echo -e "${GREEN}================================================================${NC}"

deploy() {
    local n=$1; local id=$2; local ip=$3; local target=$4; local ram=$5; local disk=$6
    ansible-playbook "$ANSIBLE_PLAYBOOK" -e "pve_api_ip=$PVE_IP pve_user=$PVE_USER pve_pass=$PVE_PASS src_node=$TPL_NODE target_node=$target vm_name=$n vm_id=$id vm_ip=$ip vm_mem=$ram vm_disk=$disk template_id=$TPL_ID storage=$STORAGE gateway=$DEFAULT_GATEWAY"
}

for i in "${!M_NAMES[@]}"; do deploy "${M_NAMES[$i]}" "${M_IDS[$i]}" "${M_IPS[$i]}" "${M_NODES[$i]}" "$M_RAM" "$M_DISK"; done
for i in "${!W_NAMES[@]}"; do deploy "${W_NAMES[$i]}" "${W_IDS[$i]}" "${W_IPS[$i]}" "${W_NODES[$i]}" "$W_RAM" "$W_DISK"; done

echo -e "\n${GREEN}✅ ¡PROCESO CONCLUIDO CON ÉXITO!${NC}"
