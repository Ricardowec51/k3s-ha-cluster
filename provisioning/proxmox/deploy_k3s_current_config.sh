#!/bin/bash

# Script de Despliegue v3.5 - ESTABLE
# Diseñado para: Ricardowec51

set -euo pipefail

# --- CONFIGURACIÓN DE RED ---
MASTER_IPS=("192.168.1.21" "192.168.1.22" "192.168.1.23")
WORKER_IPS=("192.168.1.24" "192.168.1.25" "192.168.1.26" "192.168.1.27" "192.168.1.28")

# --- Nodos Destino ---
MASTER_NODES=("BOSC" "DELL" "msa")
WORKER_NODES=("nuc10" "msn2" "msa" "msn2" "Nnuc13")

# --- Globales ---
PVE_API_IP="192.168.1.88"
PVE_USER="root@pam"
TEMPLATE_ID="9000"
STORAGE="NFS_SHARE"
GATEWAY="192.168.1.1"

# Hardware
M_RAM=8192; M_DISK="100G"
W_RAM=16384; W_DISK="500G"

ANSIBLE_PLAYBOOK="/Volumes/Externo/ansible/deploy_single_node.yml"

# --- SEGURIDAD ---
read -s -p "Introduce contraseña para Proxmox ($PVE_USER): " PVE_PASS
echo -e "\n"

# --- FASE 1: RE-CREAR PLANTILLA (Cloud-Init Limpio) ---
echo -e "\033[0;34m>>> PREPARANDO PLANTILLA BASE EN nuc10...\033[0m"
ssh -o StrictHostKeyChecking=no "root@$PVE_API_IP" << 'EOF'
    set -e
    if [ ! -f /tmp/noble.img ]; then
        wget -q --show-progress -O /tmp/noble.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    fi
    qm destroy 9000 2>/dev/null || true
    qm create 9000 --name "u24-tpl" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
    qm importdisk 9000 /tmp/noble.img NFS_SHARE
    DISK_ID=$(pvesm list NFS_SHARE | grep "vm-9000-disk" | awk '{print $1}' | head -n 1)
    qm set 9000 --scsihw virtio-scsi-pci --scsi0 $DISK_ID --ide2 NFS_SHARE:cloudinit --boot order=scsi0 --agent 1
    qm template 9000
    echo "Plantilla 9000 generada con éxito."
EOF

# --- FASE 2: DESPLEGAR ---
deploy_node() {
    local name=$1; local id=$2; local ip=$3; local node=$4; local mem=$5; local disk=$6
    
    echo -e "\n\033[0;32m[DESPLEGANDO] $name -> IP: $ip en $node\033[0m"
    ansible-playbook "$ANSIBLE_PLAYBOOK" \
        -e "pve_api_ip=$PVE_API_IP" \
        -e "pve_user=$PVE_USER" \
        -e "pve_pass=$PVE_PASS" \
        -e "src_node=nuc10" \
        -e "target_node=$node" \
        -e "vm_name=$name" \
        -e "vm_id=$id" \
        -e "vm_ip=$ip" \
        -e "vm_mem=$mem" \
        -e "vm_disk=$disk" \
        -e "template_id=$TEMPLATE_ID" \
        -e "storage=$STORAGE" \
        -e "gateway=$GATEWAY"
}

# Despliegue de Masters
echo -e "\n\033[1;33m>>> DESPLEGANDO MASTERS...\033[0m"
for i in 0 1 2; do
    deploy_node "k3s-master-$((i+1))" "$((2001+i))" "${MASTER_IPS[$i]}" "${MASTER_NODES[$i]}" "$M_RAM" "$M_DISK"
done

# Despliegue de Workers
echo -e "\n\033[1;33m>>> DESPLEGANDO WORKERS...\033[0m"
for i in 0 1 2 3 4; do
    deploy_node "k3s-worker-$((i+1))" "$((2101+i))" "${WORKER_IPS[$i]}" "${WORKER_NODES[$i]}" "$W_RAM" "$W_DISK"
done

echo -e "\n\033[0;36m✅ DESPLIEGUE FINALIZADO EXITOSAMENTE.\033[0m"
