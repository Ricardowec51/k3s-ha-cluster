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

K3S_VERSION="v1.30.13+k3s1"

# Network Configuration
MASTER1="192.168.1.21"
MASTER2="192.168.1.22"
MASTER3="192.168.1.23"
WORKER1="192.168.1.25"   # k3s-worker-02
WORKER2="192.168.1.13"   # k3s-worker-03
WORKER3="192.168.1.27"   # k3s-worker-04
VIP="192.168.1.50"
LB_RANGE="192.168.1.29-192.168.1.70"

# SSH Configuration
USER="rwagner"
INTERFACE="ens18"
CERT_NAME="id_rsa"
CONFIG_FILE=~/.ssh/config

# Arrays de nodos
MASTERS=("$MASTER2" "$MASTER3")
WORKERS=("$WORKER1" "$WORKER2" "$WORKER3")
ALL_NODES=("$MASTER1" "$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3")
ALL_EXCEPT_MASTER1=("$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3")

# Directories
KUBE_CONFIG_DIR="$HOME/.kube"
MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"

#############################################
#            HELPER FUNCTIONS               #
#############################################

log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "$timestamp - $message" | tee -a "$LOG_FILE"
}

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

command_exists() {
    command -v "$1" &> /dev/null
}

check_ssh_connectivity() {
    log "Verificando conectividad SSH con usuario $USER a todos los nodos..."
    for node in "${ALL_NODES[@]}"; do
        log "Intentando conectar a $node..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
            log "Primer intento fallido para $node, reintentando en 5 segundos..."
            sleep 5
            if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
                log "Segundo intento fallido para $node, último intento..."
                sleep 10
                if ! ssh -o BatchMode=yes -o ConnectTimeout=30 "$USER@$node" exit &>/dev/null; then
                    error_msg "No se puede conectar por SSH al nodo $node. Verifica que las claves SSH estén configuradas."
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

echo "K3S Installation Log - Started at $(date)" > "$LOG_FILE"

# 1. Verificar prerrequisitos
log "Verificando prerrequisitos..."

if [ "$SKIP_SSH_CHECK" = "false" ]; then
    log "Comprobando conectividad SSH en los nodos ${ALL_NODES[*]}..."
    check_ssh_connectivity
else
    log "Omitiendo verificación de conectividad SSH."
fi

# Sincronizar tiempo
log "Sincronizando tiempo..."
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# 2. Configurar SSH
log "Configurando SSH..."
if [ ! -f "$CONFIG_FILE" ]; then
    echo "StrictHostKeyChecking no" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    success_msg "Archivo SSH config creado"
else
    if grep -q "^StrictHostKeyChecking" "$CONFIG_FILE"; then
        if ! grep -q "^StrictHostKeyChecking no" "$CONFIG_FILE"; then
            sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$CONFIG_FILE"
        fi
    else
        echo "StrictHostKeyChecking no" >> "$CONFIG_FILE"
    fi
fi

# 3. Instalar herramientas en la máquina local
log "Instalando herramientas requeridas..."

if ! command_exists k3sup; then
    log "Instalando k3sup..."
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
    success_msg "k3sup instalado"
else
    success_msg "k3sup ya instalado"
fi

if ! command_exists kubectl; then
    log "Instalando kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    success_msg "kubectl instalado"
else
    success_msg "kubectl ya instalado"
fi

# 4. Instalar dependencias en todos los nodos
log "Instalando dependencias en todos los nodos..."
for node in "${ALL_NODES[@]}"; do
    log "Instalando policycoreutils en $node..."
    ssh -o ConnectTimeout=30 "$USER@$node" -i "$HOME/.ssh/$CERT_NAME" \
        "sudo DEBIAN_FRONTEND=noninteractive apt-get update -q && sudo NEEDRESTART_MODE=a apt-get install -y policycoreutils" \
        || warning_msg "Error al instalar policycoreutils en $node"
done
success_msg "Dependencias instaladas en todos los nodos"

# 5. Bootstrap del primer master
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

[ $? -ne 0 ] && error_msg "Error al iniciar el primer nodo maestro"
success_msg "Primer nodo maestro iniciado"

log "Esperando a que el API server esté disponible..."
sleep 45

# 6. Unir masters adicionales
log "Uniendo nodos maestros adicionales..."
for node in "${MASTERS[@]}"; do
    log "Uniendo master: $node"
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

    [ $? -ne 0 ] && error_msg "Error al unir el master $node"
    success_msg "Master $node unido"
    sleep 20
done

# 7. Unir workers
log "Uniendo nodos trabajadores..."
for node in "${WORKERS[@]}"; do
    log "Uniendo worker: $node"
    k3sup join \
        --ip "$node" \
        --user "$USER" \
        --sudo \
        --k3s-version "$K3S_VERSION" \
        --server-ip "$MASTER1" \
        --ssh-key "$HOME/.ssh/$CERT_NAME" \
        --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""

    [ $? -ne 0 ] && error_msg "Error al unir el worker $node"
    success_msg "Worker $node unido"
    sleep 20
done

log "Esperando a que todos los nodos estén registrados..."
sleep 30

# 8. Instalar MetalLB
log "Instalando MetalLB $METALLB_VERSION..."
METALLB_VERSION="v0.14.9"

kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"

log "Esperando a que MetalLB esté listo..."
kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=120s

# Configurar IP pool
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - $LB_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF

success_msg "MetalLB instalado y configurado con rango $LB_RANGE"

# 9. Configurar registry privado en todos los nodos
log "Configurando registry privado en todos los nodos..."
REGISTRY_IP="192.168.1.64"
REGISTRY_PORT="5000"

for node in "${ALL_NODES[@]}"; do
    ssh -o ConnectTimeout=30 "$USER@$node" -i "$HOME/.ssh/$CERT_NAME" "
        sudo mkdir -p /etc/rancher/k3s
        cat <<REGEOF | sudo tee /etc/rancher/k3s/registries.yaml > /dev/null
mirrors:
  \"$REGISTRY_IP:$REGISTRY_PORT\":
    endpoint:
      - \"http://$REGISTRY_IP:$REGISTRY_PORT\"
REGEOF
        sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s-agent 2>/dev/null
    " || warning_msg "Error configurando registry en $node"
done
success_msg "Registry privado configurado en todos los nodos"

# 10. Estado final
log "Despliegue completado exitosamente!"
echo "========================================"
echo "Estado del Cluster:"
echo "========================================"
kubectl get nodes -o wide
echo ""
kubectl get svc -A | grep LoadBalancer
echo ""
success_msg "API de Kubernetes disponible en: https://$MASTER1:6443"
success_msg "Registry privado disponible en: http://$REGISTRY_IP:$REGISTRY_PORT"
success_msg "Kubeconfig: $KUBE_CONFIG_DIR/config"
echo ""
echo "Log guardado en: $LOG_FILE"
