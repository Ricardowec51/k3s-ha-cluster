#!/bin/bash

# Exit on error, undefined variable, or pipe failure
set -euo pipefail

echo -e " \033[33;5m    ____  _____ ____    _    ____  ____   ___     \033[0m"
echo -e " \033[33;5m   |  _ \|_   _/ ___|  / \  |  _ \|  _ \ / _ \    \033[0m"
echo -e " \033[33;5m   | |_) | | || |     / _ \ | |_) | | | | | | |   \033[0m"
echo -e " \033[33;5m   |  _ <  | || |___ / ___ \|  _ <| |_| | |_| |   \033[0m"
echo -e " \033[33;5m   |_| \_\ |_| \____/_/   \_\_| \_\____/ \___/    \033[0m"

echo -e " \033[36;5m   __        ___    ____ _   _ _____ ____       \033[0m"
echo -e " \033[36;5m   \ \      / / \  / ___| \ | | ____|  _ \      \033[0m"
echo -e " \033[36;5m    \ \ /\ / / _ \| |  _|  \| |  _| | |_) |     \033[0m"
echo -e " \033[36;5m     \ V  V / ___ \ |_| | |\  | |___|  _ <      \033[0m"
echo -e " \033[36;5m      \_/\_/_/   \_\____|_| \_|_____|_| \_\     \033[0m"
echo -e " \033[36;5m                                                \033[0m"
echo -e " \033[32;5m            https://github/ricardowec51          \033[0m"

#############################################
# CONFIGURATION SECTION - CUSTOMIZE THESE   #
#############################################

# Opción para omitir verificación SSH (cambiar a "true" para omitir)
SKIP_SSH_CHECK="false"

# Log file path
LOG_FILE="k3s_install_$(date +%Y%m%d-%H%M%S).log"

# Version of Kube-VIP and K3S to deploy
KVVERSION="v0.8.9"
K3S_VERSION="v1.30.10+k3s1"

# Network Configuration
MASTER1="192.168.56.21"
MASTER2="192.168.56.22"
MASTER3="192.168.56.23"
WORKER1="192.168.56.24"
WORKER2="192.168.56.25"
# Nuevos nodos trabajadores
WORKER3="192.168.56.26"
WORKER4="192.168.56.27"
WORKER5="192.168.56.28"
VIP="192.168.56.50"
LB_RANGE="192.168.56.60-192.168.56.80"

# SSH Configuration
USER="rwagner"
INTERFACE="ens18"
CERT_NAME="id_rsa"
CONFIG_FILE=~/.ssh/config

# Arrays de nodos
MASTERS=("$MASTER2" "$MASTER3")
# Array actualizado con todos los trabajadores
WORKERS=("$WORKER1" "$WORKER2" "$WORKER3" "$WORKER4" "$WORKER5")
# Array actualizado con todos los nodos
ALL_NODES=("$MASTER1" "$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3" "$WORKER4" "$WORKER5")
# Array actualizado con todos excepto el primer maestro
ALL_EXCEPT_MASTER1=("$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3" "$WORKER4" "$WORKER5")

# Directories
KUBE_CONFIG_DIR="$HOME/.kube"
MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"

#############################################
#            HELPER FUNCTIONS               #
#############################################

# Function for logging
log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "$timestamp - $message" | tee -a "$LOG_FILE"
}

# Function to display color-coded status messages
success_msg() {
    log "\033[32;5m$1\033[0m"
}

error_msg() {
    log "\033[31;5m$1\033[0m"
    exit 1
}

warning_msg() {
    log "\033[33;5m$1\033[0m"
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Function to check SSH access to all nodes
check_ssh_connectivity() {
    log "Verificando conectividad SSH con usuario $USER a todos los nodos..."
    for node in "${ALL_NODES[@]}"; do
        log "Intentando conectar a $node..."
        # Aumentamos el timeout a 30 segundos
        if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
            # Intentar nuevamente antes de fallar
            log "Primer intento fallido para $node, intentando nuevamente en 5 segundos..."
            sleep 5
            if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
                log "Segundo intento fallido para $node, intentando un último intento..."
                sleep 10
                if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
                    error_msg "No se puede conectar por SSH al nodo $node con el usuario $USER. Verifica que las claves SSH estén correctamente configuradas."
                fi
            fi
        fi
        log "Conexión exitosa a $node"
    done
    success_msg "Conectividad SSH establecida con todos los nodos."
}

#############################################
#            INSTALLATION STEPS             #
#############################################

# Initialize log file
echo "K3S Installation Log - Started at $(date)" > "$LOG_FILE"

# 1. Check prerequisites
log "Verificando prerrequisitos..."

# Verificar conectividad SSH con los nodos
if [ "$SKIP_SSH_CHECK" = "false" ]; then
    log "Comprobando conectividad SSH con usuario $USER en los nodos 192.168.56.21-28..."
    check_ssh_connectivity
else
    log "Omitiendo verificación de conectividad SSH por configuración."
fi

# Ya no es necesario copiar las claves SSH, ya están configuradas
log "Las claves SSH ya están configuradas en todos los nodos. Omitiendo paso de copia de claves."

# Fix time synchronization (useful when running in VMs)
log "Sincronizando tiempo..."
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# 2. Setup SSH configuration
log "Configurando SSH..."

# Check for SSH config file, create if needed
if [ ! -f "$CONFIG_FILE" ]; then
    echo "StrictHostKeyChecking no" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    success_msg "Archivo de configuración SSH creado con StrictHostKeyChecking deshabilitado"
else
    if grep -q "^StrictHostKeyChecking" "$CONFIG_FILE"; then
        if ! grep -q "^StrictHostKeyChecking no" "$CONFIG_FILE"; then
            sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$CONFIG_FILE"
            success_msg "SSH StrictHostKeyChecking configurado a 'no'"
        fi
    else
        echo "StrictHostKeyChecking no" >> "$CONFIG_FILE"
        success_msg "SSH StrictHostKeyChecking añadido"
    fi
fi

# Skip copying SSH keys as they are already configured
log "Se omite la copia de claves SSH ya que están previamente configuradas"

# 3. Install required tools on local machine
log "Instalando herramientas requeridas..."

# Install k3sup
if ! command_exists k3sup; then
    log "Instalando k3sup..."
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
    success_msg "k3sup instalado exitosamente"
else
    success_msg "k3sup ya está instalado"
fi

# Install kubectl
if ! command_exists kubectl; then
    log "Instalando kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    success_msg "kubectl instalado exitosamente"
else
    success_msg "kubectl ya está instalado"
fi

# 4. Install dependencies on all nodes
log "Instalando dependencias en todos los nodos..."
for node in "${ALL_NODES[@]}"; do
    log "Instalando policycoreutils en $node..."
    ssh -o ConnectTimeout=30 "$USER@$node" -i "/home/$USER/.ssh/$CERT_NAME" "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo NEEDRESTART_MODE=a apt-get install -y policycoreutils" || warning_msg "Error al instalar policycoreutils en $node"
done
success_msg "Dependencias instaladas en todos los nodos"

# 5. Bootstrap first master node
log "Iniciando el primer nodo maestro ($MASTER1)..."
mkdir -p "$KUBE_CONFIG_DIR"

k3sup install \
    --ip "$MASTER1" \
    --user "$USER" \
    --tls-san "$VIP" \
    --cluster \
    --k3s-version "$K3S_VERSION" \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$INTERFACE --node-ip=$MASTER1 --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --merge \
    --sudo \
    --local-path "$KUBE_CONFIG_DIR/config" \
    --ssh-key "$HOME/.ssh/$CERT_NAME" \
    --context k3s-ha

if [ $? -ne 0 ]; then
    error_msg "Error al iniciar el primer nodo maestro"
fi
success_msg "Primer nodo maestro iniciado exitosamente"

# 6. Install Kube-VIP for HA - MODIFICADO PARA APLICAR DIRECTAMENTE EN EL NODO MAESTRO
log "Configurando kube-vip para alta disponibilidad..."

# Esperar a que el servidor API esté disponible
log "Esperando a que el servidor API esté completamente disponible..."
sleep 45

# Aplicar RBAC directamente en el nodo maestro
log "Aplicando RBAC de kube-vip directamente en el nodo maestro..."
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" <<EOF
  sudo curl -s https://kube-vip.io/manifests/rbac.yaml -o /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml
EOF

# 7. Download kube-vip manifest and update variables
log "Descargando y configurando manifest de kube-vip..."
curl -sO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/kube-vip
cat kube-vip | sed "s/\$interface/$INTERFACE/g; s/\$vip/$VIP/g" > "$HOME/kube-vip.yaml"

# 8. Copy kube-vip.yaml to master1
log "Copiando kube-vip.yaml al primer nodo maestro..."
scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/kube-vip.yaml" "$USER@$MASTER1:~/kube-vip.yaml"

# 9. Move kube-vip.yaml to manifests directory on master1
log "Moviendo kube-vip.yaml al directorio de manifests en el primer nodo maestro..."
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo mkdir -p $MANIFEST_DIR && sudo mv kube-vip.yaml $MANIFEST_DIR/kube-vip.yaml"
success_msg "Configuración de kube-vip desplegada en master1"

# Esperar a que kube-vip se inicie
log "Esperando a que kube-vip se inicie correctamente..."
sleep 30

# 10. Join additional master nodes
log "Uniendo nodos maestros adicionales..."
for node in "${MASTERS[@]}"; do
    log "Uniendo nodo maestro: $node"
    k3sup join \
        --ip "$node" \
        --user "$USER" \
        --sudo \
        --k3s-version "$K3S_VERSION" \
        --server \
        --server-ip "$MASTER1" \
        --ssh-key "$HOME/.ssh/$CERT_NAME" \
        --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$INTERFACE --node-ip=$node --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
        --server-user "$USER"
    
    if [ $? -ne 0 ]; then
        error_msg "Error al unir el nodo maestro $node"
    fi
    success_msg "Nodo maestro $node unido exitosamente"
    
    # Esperar a que el nodo se una correctamente antes de continuar con el siguiente
    log "Esperando a que el nodo maestro $node se una completamente..."
    sleep 20
done

# 11. Join worker nodes
log "Uniendo nodos trabajadores..."
for node in "${WORKERS[@]}"; do
    log "Uniendo nodo trabajador: $node"
    k3sup join \
        --ip "$node" \
        --user "$USER" \
        --sudo \
        --k3s-version "$K3S_VERSION" \
        --server-ip "$MASTER1" \
        --ssh-key "$HOME/.ssh/$CERT_NAME" \
        --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""
    
    if [ $? -ne 0 ]; then
        error_msg "Error al unir el nodo trabajador $node"
    fi
    success_msg "Nodo trabajador $node unido exitosamente"
    
    # Esperar a que el nodo se una correctamente antes de continuar con el siguiente
    log "Esperando a que el nodo trabajador $node se una completamente..."
    sleep 20
done

# Esperar a que todos los nodos estén correctamente registrados
log "Esperando a que todos los nodos estén correctamente registrados..."
sleep 30

# 12. Install kube-vip as network LoadBalancer - Install the kube-vip Cloud Provider
log "Instalando kube-vip como proveedor de balanceo de carga..."
# MODIFICADO PARA APLICAR DIRECTAMENTE EN EL NODO MAESTRO
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" <<EOF
  sudo curl -s https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml -o /var/lib/rancher/k3s/server/manifests/kube-vip-cloud-controller.yaml
EOF

# 13. Install MetalLB
log "Instalando MetalLB..."
# MODIFICADO PARA APLICAR DIRECTAMENTE EN EL NODO MAESTRO
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" <<EOF
  sudo curl -s https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml -o /var/lib/rancher/k3s/server/manifests/metallb-namespace.yaml
  sudo curl -s https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml -o /var/lib/rancher/k3s/server/manifests/metallb-native.yaml
EOF

# Esperar a que MetalLB se instale correctamente
log "Esperando a que MetalLB se instale correctamente..."
sleep 30

# Configure MetalLB IP address pool
log "Configurando rango de IPs para MetalLB..."
curl -sO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/ipAddressPool
cat ipAddressPool | sed "s/\$lbrange/$LB_RANGE/g" > "$HOME/ipAddressPool.yaml"

# Copiar y aplicar ipAddressPool directamente en el nodo maestro
scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/ipAddressPool.yaml" "$USER@$MASTER1:~/ipAddressPool.yaml"
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo mv ipAddressPool.yaml /var/lib/rancher/k3s/server/manifests/ipAddressPool.yaml"

# Aplicar L2Advertisement directamente en el nodo maestro
log "Aplicando configuración L2Advertisement para MetalLB..."
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" <<EOF
  sudo curl -s https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/l2Advertisement.yaml -o /var/lib/rancher/k3s/server/manifests/l2Advertisement.yaml
EOF
success_msg "MetalLB configurado exitosamente"

# 14. Deploy test application - MODIFICADO PARA APLICAR DIRECTAMENTE EN EL NODO MAESTRO
log "Desplegando aplicación de prueba Nginx..."
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" <<EOF
  sudo curl -s https://raw.githubusercontent.com/inlets/inlets-operator/master/contrib/nginx-sample-deployment.yaml -o /var/lib/rancher/k3s/server/manifests/nginx-sample-deployment.yaml
  sudo kubectl expose deployment nginx-1 --port=80 --type=LoadBalancer -n default --kubeconfig /etc/rancher/k3s/k3s.yaml
EOF

# Wait for Nginx to be ready
log "Esperando a que los pods de Nginx estén listos..."
echo "Esto puede tomar unos minutos..."

# Counter for timeout
timeout_counter=0
max_timeout=300  # 5 minutos

while [[ $(ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo kubectl get pods -l app=nginx -o 'jsonpath={..status.conditions[?(@.type==\"Ready\")].status}' --kubeconfig /etc/rancher/k3s/k3s.yaml" 2>/dev/null) != "True" ]]; do
   echo -n "."
   sleep 2
   ((timeout_counter+=2))
   
   if [ $timeout_counter -ge $max_timeout ]; then
     warning_msg "Tiempo de espera agotado esperando que Nginx esté listo. Continuando de todos modos..."
     break
   fi
done
echo

# 15. Show final status
log "¡Despliegue completado exitosamente!"
echo "========================================"
echo "Estado del Cluster:"
echo "========================================"

# Obtener información desde el nodo maestro para evitar problemas de autenticación
log "Obteniendo información de nodos desde el nodo maestro:"
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo kubectl get nodes -o wide --kubeconfig /etc/rancher/k3s/k3s.yaml"

log "Obteniendo información de servicios desde el nodo maestro:"
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo kubectl get svc --all-namespaces --kubeconfig /etc/rancher/k3s/k3s.yaml"

log "Obteniendo información de pods desde el nodo maestro:"
ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo kubectl get pods --all-namespaces -o wide --kubeconfig /etc/rancher/k3s/k3s.yaml"

# Get Nginx external IP
log "Esperando a que se asigne una IP externa a Nginx (puede tomar un tiempo)..."
for i in {1..10}; do
    NGINX_IP=$(ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" "sudo kubectl get svc nginx-1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --kubeconfig /etc/rancher/k3s/k3s.yaml" 2>/dev/null || echo "")
    if [ -n "$NGINX_IP" ]; then
        break
    fi
    echo "Intento $i: IP externa aún no disponible. Esperando 15 segundos más..."
    sleep 15
done

success_msg "¡Despliegue del Cluster K3S HA completado exitosamente!"

if [ -n "$NGINX_IP" ]; then
    success_msg "Accede a la aplicación de prueba Nginx en: http://$NGINX_IP"
else
    warning_msg "La IP externa de Nginx no está disponible aún. Puedes verificarla más tarde con: ssh $USER@$MASTER1 'sudo kubectl get svc'"
fi

success_msg "API de Kubernetes disponible en: https://$VIP:6443"
success_msg "Ubicación del archivo kubeconfig: $KUBE_CONFIG_DIR/config"
echo
echo "Log de instalación guardado en: $LOG_FILE"
