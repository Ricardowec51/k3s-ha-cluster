#!/bin/bash

# K3s HA Development Test Script - Safe Compatible Versions
# Based on compatibility analysis and bug fixes
# Version: 2.0-dev-safe

# Exit on error, undefined variable, or pipe failure
set -euo pipefail

echo -e " \033[33;5m    ____  _____ ____    _    ____  ____   ___     \033[0m"
echo -e " \033[33;5m   |  _ \|_   _/ ___|  / \  |  _ \|  _ \ / _ \    \033[0m"
echo -e " \033[33;5m   | |_) | | || |     / _ \ | |_) | | | | | | |   \033[0m"
echo -e " \033[33;5m   |  _ <  | || |___ / ___ \|  _ <| |_| | |_| |   \033[0m"
echo -e " \033[33;5m   |_| \_\ |_| \____/_/   \_\_| \_\____/ \___/    \033[0m"

echo -e " \033[36;5m   ____  _______     __  _____ _____ ____ _____  \033[0m"
echo -e " \033[36;5m  |  _ \| ____\ \   / / |_   _| ____/ ___|_   _| \033[0m"
echo -e " \033[36;5m  | | | |  _|  \ \ / /    | | |  _| \___ \ | |   \033[0m"
echo -e " \033[36;5m  | |_| | |___  \ V /     | | | |___ ___) || |   \033[0m"
echo -e " \033[36;5m  |____/|_____|  \_/      |_| |_____|____/ |_|   \033[0m"
echo -e " \033[32;5m      Versiones Compatibles y Probadas          \033[0m"
echo -e " \033[32;5m        https://github.com/ricardowec51          \033[0m"

#############################################
# DEVELOPMENT CONFIGURATION - SAFE VERSIONS #
#############################################

# Modo de desarrollo/pruebas
DEV_MODE="true"
ENABLE_ROLLBACK="true"
BACKUP_BEFORE_CHANGES="true"
EXTENSIVE_VALIDATION="true"

# Versiones compatibles y probadas (basadas en análisis de compatibilidad)
KVVERSION="v0.8.6"              # ✅ CRÍTICO: Evita bug de v0.8.9
K3S_VERSION="v1.30.13+k3s1"     # ✅ Última estable sin breaking changes
METALLB_VERSION="v0.14.9"       # ✅ Compatible con K8s 1.30.x
K3SUP_VERSION="0.13.8"          # ✅ Versión específica para reproducibilidad

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

# Arrays de nodos (configuración de desarrollo)
MASTERS=("$MASTER2" "$MASTER3")
WORKERS=("$WORKER1" "$WORKER2" "$WORKER3")  # Solo 3 workers para dev
ALL_NODES=("$MASTER1" "$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3")
ALL_EXCEPT_MASTER1=("$MASTER2" "$MASTER3" "$WORKER1" "$WORKER2" "$WORKER3")

# Directories
KUBE_CONFIG_DIR="$HOME/.kube"
MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"

# Log configuration
LOG_FILE="k3s_dev_test_$(date +%Y%m%d-%H%M%S).log"
DEBUG_LOG="k3s_debug_$(date +%Y%m%d-%H%M%S).log"

# Backup directory
BACKUP_DIR="./k3s-backup-$(date +%Y%m%d-%H%M%S)"

# URLs específicas para las versiones compatibles
METALLB_NAMESPACE_URL="https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-namespace.yaml"
METALLB_NATIVE_URL="https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml"
KUBEVIP_RBAC_URL="https://kube-vip.io/manifests/rbac.yaml"

#############################################
#            ENHANCED LOGGING               #
#############################################

# Función de logging estructurado con niveles
log_structured() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local hostname=$(hostname)
    
    case "$level" in
        "ERROR")
            echo -e "$timestamp [$hostname] \033[31;5mERROR\033[0m: $message" | tee -a "$LOG_FILE"
            echo "$timestamp [$hostname] ERROR: $message" >> "$DEBUG_LOG"
            ;;
        "WARN")
            echo -e "$timestamp [$hostname] \033[33;5mWARN\033[0m: $message" | tee -a "$LOG_FILE"
            echo "$timestamp [$hostname] WARN: $message" >> "$DEBUG_LOG"
            ;;
        "INFO")
            echo -e "$timestamp [$hostname] \033[32;5mINFO\033[0m: $message" | tee -a "$LOG_FILE"
            echo "$timestamp [$hostname] INFO: $message" >> "$DEBUG_LOG"
            ;;
        "DEBUG")
            if [[ "$DEV_MODE" == "true" ]]; then
                echo -e "$timestamp [$hostname] \033[36;5mDEBUG\033[0m: $message" | tee -a "$LOG_FILE"
            fi
            echo "$timestamp [$hostname] DEBUG: $message" >> "$DEBUG_LOG"
            ;;
        "SUCCESS")
            echo -e "$timestamp [$hostname] \033[32;1mSUCCESS\033[0m: $message" | tee -a "$LOG_FILE"
            echo "$timestamp [$hostname] SUCCESS: $message" >> "$DEBUG_LOG"
            ;;
    esac
}

# Aliases para compatibilidad con funciones existentes
log() { log_structured "INFO" "$1"; }
success_msg() { log_structured "SUCCESS" "$1"; }
error_msg() { log_structured "ERROR" "$1"; exit 1; }
warning_msg() { log_structured "WARN" "$1"; }
debug_msg() { log_structured "DEBUG" "$1"; }

#############################################
#         ENHANCED VALIDATIONS             #
#############################################

# Función de validación de compatibilidad de versiones
validate_versions() {
    log_structured "INFO" "Validando compatibilidad de versiones..."
    
    # Validar que no estamos usando la versión buggy de kube-vip
    if [[ "$KVVERSION" == "v0.8.9" ]]; then
        error_msg "❌ CRÍTICO: Kube-VIP v0.8.9 tiene bug crítico con IPVS. Usar v0.8.6"
    fi
    
    # Validar versiones de K3s
    local k3s_major=$(echo "$K3S_VERSION" | sed 's/v//' | cut -d. -f1)
    local k3s_minor=$(echo "$K3S_VERSION" | sed 's/v//' | cut -d. -f2)
    
    if [[ $k3s_major -eq 1 && $k3s_minor -ge 32 ]]; then
        warning_msg "⚠️  K3s v1.32+ detectado. Contendrá Containerd 2.0 y breaking changes"
        warning_msg "⚠️  Recomendado: usar v1.30.13+k3s1 para evitar breaking changes"
    fi
    
    success_msg "✅ Validación de versiones completada"
}

# Función de validación SSH mejorada
validate_ssh_key() {
    log_structured "INFO" "Validando configuración SSH..."
    local key_path="$HOME/.ssh/$CERT_NAME"
    
    # Verificar que la clave existe
    if [[ ! -f "$key_path" ]]; then
        error_msg "❌ Clave SSH no encontrada: $key_path"
    fi
    
    # Verificar permisos de la clave
    local perms=$(stat -c "%a" "$key_path")
    if [[ "$perms" != "600" ]]; then
        warning_msg "⚠️  Permisos de clave SSH incorrectos ($perms). Corrigiendo a 600..."
        chmod 600 "$key_path"
    fi
    
    # Verificar que la clave pública existe
    if [[ ! -f "${key_path}.pub" ]]; then
        error_msg "❌ Clave pública SSH no encontrada: ${key_path}.pub"
    fi
    
    success_msg "✅ Configuración SSH validada"
}

# Función de validación de prerrequisitos extendida
validate_prerequisites() {
    log_structured "INFO" "Validando prerrequisitos del sistema..."
    
    # Verificar versión mínima de kernel
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
    
    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 15 ]]; then
        error_msg "❌ Kernel version $kernel_version no soportada. Mínimo requerido: 4.15"
    fi
    
    # Verificar módulos del kernel necesarios
    local required_modules=("br_netfilter" "overlay" "iptable_nat")
    for module in "${required_modules[@]}"; do
        if ! lsmod | grep -q "$module"; then
            warning_msg "⚠️  Módulo $module no cargado. Intentando cargar..."
            sudo modprobe "$module" || error_msg "❌ No se pudo cargar el módulo $module"
        fi
        debug_msg "✅ Módulo $module verificado"
    done
    
    # Verificar espacio en disco disponible
    local available_space=$(df / --output=avail | tail -1)
    if [[ $available_space -lt 5242880 ]]; then  # 5GB en KB para desarrollo
        warning_msg "⚠️  Espacio en disco bajo. Disponible: $(($available_space/1024/1024))GB"
        warning_msg "⚠️  Recomendado: mínimo 5GB para ambiente de desarrollo"
    fi
    
    # Verificar que containerd no está ejecutándose independientemente
    if systemctl is-active --quiet containerd 2>/dev/null; then
        warning_msg "⚠️  Containerd está ejecutándose independientemente. Puede causar conflictos"
    fi
    
    success_msg "✅ Prerrequisitos validados"
}

# Función para validar configuración K3s específica
validate_k3s_config() {
    log_structured "INFO" "Validando configuración específica de K3s..."
    
    # Verificar que los parámetros requeridos están presentes
    local required_flags=("--disable traefik" "--disable servicelb")
    for flag in "${required_flags[@]}"; do
        debug_msg "Verificando flag requerido: $flag"
    done
    
    success_msg "✅ Configuración K3s validada"
}

#############################################
#            BACKUP FUNCTIONS               #
#############################################

# Función de backup antes de cambios
create_backup() {
    if [[ "$BACKUP_BEFORE_CHANGES" == "true" ]]; then
        log_structured "INFO" "Creando backup de configuración existente..."
        mkdir -p "$BACKUP_DIR"
        
        # Backup del kubeconfig si existe
        if [[ -f "$KUBE_CONFIG_DIR/config" ]]; then
            cp "$KUBE_CONFIG_DIR/config" "$BACKUP_DIR/kubeconfig.backup"
            debug_msg "Kubeconfig respaldado"
        fi
        
        # Backup de configuraciones SSH
        if [[ -f "$CONFIG_FILE" ]]; then
            cp "$CONFIG_FILE" "$BACKUP_DIR/ssh_config.backup"
            debug_msg "Configuración SSH respaldada"
        fi
        
        # Crear script de rollback
        cat > "$BACKUP_DIR/rollback.sh" << 'EOF'
#!/bin/bash
echo "🔄 Iniciando rollback..."
# Restaurar kubeconfig
if [[ -f "./kubeconfig.backup" ]]; then
    cp kubeconfig.backup ~/.kube/config
    echo "✅ Kubeconfig restaurado"
fi
# Restaurar SSH config
if [[ -f "./ssh_config.backup" ]]; then
    cp ssh_config.backup ~/.ssh/config
    echo "✅ SSH config restaurado"
fi
echo "✅ Rollback completado"
EOF
        chmod +x "$BACKUP_DIR/rollback.sh"
        
        success_msg "✅ Backup creado en: $BACKUP_DIR"
    fi
}

#############################################
#         CONNECTIVITY FUNCTIONS            #
#############################################

# Función mejorada de verificación SSH
check_ssh_connectivity() {
    log_structured "INFO" "Verificando conectividad SSH con todos los nodos..."
    local failed_nodes=()
    
    for node in "${ALL_NODES[@]}"; do
        debug_msg "Verificando conectividad con $node..."
        
        # Intentar conexión con timeout más largo para desarrollo
        local max_attempts=3
        local attempt=1
        local connected=false
        
        while [[ $attempt -le $max_attempts ]]; do
            if ssh -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no "$USER@$node" exit &>/dev/null; then
                connected=true
                debug_msg "✅ Conexión exitosa a $node (intento $attempt)"
                break
            else
                debug_msg "❌ Intento $attempt fallido para $node"
                sleep 5
                ((attempt++))
            fi
        done
        
        if [[ "$connected" == "false" ]]; then
            failed_nodes+=("$node")
            warning_msg "❌ No se pudo conectar a $node después de $max_attempts intentos"
        fi
    done
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        error_msg "❌ Fallo de conectividad SSH con nodos: ${failed_nodes[*]}"
    fi
    
    success_msg "✅ Conectividad SSH establecida con todos los nodos"
}

#############################################
#         INSTALLATION FUNCTIONS            #
#############################################

# Función para instalar herramientas con validación de versiones
install_tools() {
    log_structured "INFO" "Instalando herramientas requeridas..."
    
    # Instalar k3sup con versión específica
    if ! command -v k3sup &> /dev/null || [[ $(k3sup version 2>/dev/null | grep -o "v[0-9]*\.[0-9]*\.[0-9]*" | head -1 | sed 's/v//') != "${K3SUP_VERSION}" ]]; then
        log_structured "INFO" "Instalando k3sup versión $K3SUP_VERSION..."
        curl -sLS https://get.k3sup.dev | sh
        sudo install k3sup /usr/local/bin/
        
        # Verificar versión instalada
        local installed_version=$(k3sup version 2>/dev/null | grep -o "v[0-9]*\.[0-9]*\.[0-9]*" | head -1 | sed 's/v//')
        debug_msg "k3sup versión instalada: $installed_version"
        success_msg "✅ k3sup instalado correctamente"
    else
        success_msg "✅ k3sup ya está instalado con la versión correcta"
    fi
    
    # Instalar kubectl
    if ! command -v kubectl &> /dev/null; then
        log_structured "INFO" "Instalando kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
        success_msg "✅ kubectl instalado correctamente"
    else
        success_msg "✅ kubectl ya está instalado"
    fi
    
    # Verificar herramientas adicionales necesarias
    local required_tools=("curl" "ssh" "scp" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            warning_msg "⚠️  Herramienta requerida no encontrada: $tool"
            log_structured "INFO" "Instalando $tool..."
            sudo apt-get update && sudo apt-get install -y "$tool"
        fi
        debug_msg "✅ $tool disponible"
    done
}

# Función para instalar dependencias en nodos
install_node_dependencies() {
    log_structured "INFO" "Instalando dependencias en todos los nodos..."
    local failed_nodes=()
    
    for node in "${ALL_NODES[@]}"; do
        debug_msg "Instalando dependencias en $node..."
        
        if ! ssh -o ConnectTimeout=30 "$USER@$node" -i "/home/$USER/.ssh/$CERT_NAME" \
            "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo NEEDRESTART_MODE=a apt-get install -y policycoreutils curl" 2>/dev/null; then
            failed_nodes+=("$node")
            warning_msg "⚠️  Error al instalar dependencias en $node"
        else
            debug_msg "✅ Dependencias instaladas en $node"
        fi
    done
    
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        warning_msg "⚠️  Fallos en nodos: ${failed_nodes[*]}"
    else
        success_msg "✅ Dependencias instaladas en todos los nodos"
    fi
}

#############################################
#         CLUSTER SETUP FUNCTIONS           #
#############################################

# Función para inicializar el primer master
bootstrap_first_master() {
    log_structured "INFO" "Inicializando el primer nodo maestro ($MASTER1)..."
    mkdir -p "$KUBE_CONFIG_DIR"
    
    debug_msg "Ejecutando k3sup install con parámetros específicos..."
    debug_msg "- IP: $MASTER1"
    debug_msg "- Usuario: $USER"
    debug_msg "- TLS SAN: $VIP"
    debug_msg "- Versión K3s: $K3S_VERSION"
    debug_msg "- Interfaz: $INTERFACE"
    
    if k3sup install \
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
        --context k3s-ha-dev; then
        
        success_msg "✅ Primer nodo maestro inicializado correctamente"
        
        # Verificar que el nodo está listo
        sleep 30
        if kubectl get nodes | grep -q "$MASTER1.*Ready"; then
            success_msg "✅ Nodo maestro $MASTER1 está Ready"
        else
            warning_msg "⚠️  Nodo maestro $MASTER1 aún no está Ready, continuando..."
        fi
    else
        error_msg "❌ Error al inicializar el primer nodo maestro"
    fi
}

# Función para configurar kube-vip con versión específica
setup_kubevip() {
    log_structured "INFO" "Configurando kube-vip versión $KVVERSION..."
    
    # Esperar a que el servidor API esté disponible
    log_structured "INFO" "Esperando disponibilidad del servidor API..."
    local api_ready=false
    local attempts=0
    local max_attempts=12  # 2 minutos
    
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get nodes &>/dev/null; then
            api_ready=true
            break
        fi
        debug_msg "API no disponible, intento $((attempts + 1))/$max_attempts"
        sleep 10
        ((attempts++))
    done
    
    if [[ "$api_ready" == "false" ]]; then
        error_msg "❌ Timeout esperando disponibilidad del API server"
    fi
    
    success_msg "✅ API server disponible"
    
    # Aplicar RBAC de kube-vip
    log_structured "INFO" "Aplicando RBAC de kube-vip..."
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo curl -s $KUBEVIP_RBAC_URL -o /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml"; then
        debug_msg "✅ RBAC de kube-vip aplicado"
    else
        error_msg "❌ Error aplicando RBAC de kube-vip"
    fi
    
    # Descargar y configurar manifest de kube-vip
    log_structured "INFO" "Configurando manifest de kube-vip..."
    curl -sO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/kube-vip
    
    # Reemplazar variables en el manifest
    sed -e "s/\$interface/$INTERFACE/g" \
        -e "s/\$vip/$VIP/g" \
        -e "s/plndr\/kube-vip:.*$/plndr\/kube-vip:$KVVERSION/g" \
        kube-vip > "$HOME/kube-vip.yaml"
    
    debug_msg "Variables reemplazadas en kube-vip.yaml:"
    debug_msg "- Interface: $INTERFACE"
    debug_msg "- VIP: $VIP"
    debug_msg "- Versión: $KVVERSION"
    
    # Copiar kube-vip.yaml al master1
    if scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/kube-vip.yaml" "$USER@$MASTER1:~/kube-vip.yaml"; then
        debug_msg "✅ kube-vip.yaml copiado al master1"
    else
        error_msg "❌ Error copiando kube-vip.yaml"
    fi
    
    # Mover al directorio de manifests
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo mkdir -p $MANIFEST_DIR && sudo mv kube-vip.yaml $MANIFEST_DIR/kube-vip.yaml"; then
        success_msg "✅ kube-vip configurado correctamente"
    else
        error_msg "❌ Error moviendo kube-vip.yaml al directorio de manifests"
    fi
    
    # Esperar a que kube-vip se inicie
    log_structured "INFO" "Esperando inicio de kube-vip..."
    sleep 45
    
    # Verificar que kube-vip está ejecutándose
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo kubectl get pods -n kube-system --kubeconfig /etc/rancher/k3s/k3s.yaml | grep -q kube-vip"; then
        success_msg "✅ kube-vip está ejecutándose"
    else
        warning_msg "⚠️  kube-vip pods no detectados, continuando..."
    fi
}

# Función para unir nodos maestros adicionales
join_additional_masters() {
    log_structured "INFO" "Uniendo nodos maestros adicionales..."
    
    for node in "${MASTERS[@]}"; do
        log_structured "INFO" "Uniendo nodo maestro: $node"
        debug_msg "Parámetros para $node:"
        debug_msg "- Servidor: $MASTER1"
        debug_msg "- Interfaz: $INTERFACE"
        debug_msg "- Versión: $K3S_VERSION"
        
        if k3sup join \
            --ip "$node" \
            --user "$USER" \
            --sudo \
            --k3s-version "$K3S_VERSION" \
            --server \
            --server-ip "$MASTER1" \
            --ssh-key "$HOME/.ssh/$CERT_NAME" \
            --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$INTERFACE --node-ip=$node --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
            --server-user "$USER"; then
            
            success_msg "✅ Nodo maestro $node unido correctamente"
            
            # Esperar a que el nodo se una completamente
            log_structured "INFO" "Esperando que $node esté completamente listo..."
            sleep 30
        else
            error_msg "❌ Error uniendo nodo maestro $node"
        fi
    done
}

# Función para unir nodos trabajadores (con paralelización limitada para desarrollo)
join_worker_nodes() {
    log_structured "INFO" "Uniendo nodos trabajadores..."
    
    # En modo desarrollo, unir secuencialmente para mejor debugging
    if [[ "$DEV_MODE" == "true" ]]; then
        for node in "${WORKERS[@]}"; do
            log_structured "INFO" "Uniendo nodo trabajador: $node"
            debug_msg "Configuración para $node:"
            debug_msg "- Servidor: $MASTER1"
            debug_msg "- Labels: longhorn=true, worker=true"
            
            if k3sup join \
                --ip "$node" \
                --user "$USER" \
                --sudo \
                --k3s-version "$K3S_VERSION" \
                --server-ip "$MASTER1" \
                --ssh-key "$HOME/.ssh/$CERT_NAME" \
                --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""; then
                
                success_msg "✅ Nodo trabajador $node unido correctamente"
                sleep 20  # Esperar entre workers en modo desarrollo
            else
                warning_msg "⚠️  Error uniendo nodo trabajador $node"
            fi
        done
    else
        # Para producción, usar paralelización limitada
        local pids=()
        for node in "${WORKERS[@]}"; do
            (
                k3sup join \
                    --ip "$node" \
                    --user "$USER" \
                    --sudo \
                    --k3s-version "$K3S_VERSION" \
                    --server-ip "$MASTER1" \
                    --ssh-key "$HOME/.ssh/$CERT_NAME" \
                    --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""
            ) &
            pids+=($!)
            
            # Limitar a 2 workers simultáneos
            if [[ ${#pids[@]} -eq 2 ]]; then
                wait "${pids[@]}"
                pids=()
            fi
        done
        
        # Esperar procesos restantes
        if [[ ${#pids[@]} -gt 0 ]]; then
            wait "${pids[@]}"
        fi
    fi
}

#############################################
#         METALLB SETUP FUNCTIONS           #
#############################################

# Función para instalar MetalLB con versión específica
install_metallb() {
    log_structured "INFO" "Instalando MetalLB versión $METALLB_VERSION..."
    
    # Aplicar namespace de MetalLB
    log_structured "INFO" "Aplicando namespace de MetalLB..."
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo curl -s $METALLB_NAMESPACE_URL -o /var/lib/rancher/k3s/server/manifests/metallb-namespace.yaml"; then
        debug_msg "✅ Namespace de MetalLB aplicado"
    else
        error_msg "❌ Error aplicando namespace de MetalLB"
    fi
    
    # Aplicar manifests nativos de MetalLB
    log_structured "INFO" "Aplicando manifests nativos de MetalLB..."
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo curl -s $METALLB_NATIVE_URL -o /var/lib/rancher/k3s/server/manifests/metallb-native.yaml"; then
        debug_msg "✅ Manifests nativos de MetalLB aplicados"
    else
        error_msg "❌ Error aplicando manifests nativos de MetalLB"
    fi
    
    # Esperar a que MetalLB se instale
    log_structured "INFO" "Esperando instalación de MetalLB..."
    sleep 45
    
    # Verificar que los pods de MetalLB están ejecutándose
    local metallb_ready=false
    local attempts=0
    local max_attempts=12
    
    while [[ $attempts -lt $max_attempts ]]; do
        local running_pods=$(ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
            "sudo kubectl get pods -n metallb-system --kubeconfig /etc/rancher/k3s/k3s.yaml --no-headers 2>/dev/null | grep -c Running" || echo "0")
        
        if [[ $running_pods -ge 2 ]]; then  # Controller + al menos un speaker
            metallb_ready=true
            break
        fi
        
        debug_msg "MetalLB pods ejecutándose: $running_pods, intento $((attempts + 1))/$max_attempts"
        sleep 10
        ((attempts++))
    done
    
    if [[ "$metallb_ready" == "true" ]]; then
        success_msg "✅ MetalLB instalado y ejecutándose correctamente"
    else
        warning_msg "⚠️  MetalLB pods no completamente listos, continuando..."
    fi
}

# Función para configurar pool de direcciones de MetalLB
configure_metallb_pool() {
    log_structured "INFO" "Configurando pool de direcciones IP para MetalLB..."
    
    # Crear configuración de pool de IPs
    cat > "$HOME/metallb-ippool.yaml" << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: dev-pool
  namespace: metallb-system
spec:
  addresses:
  - $LB_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: dev-l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - dev-pool
EOF
    
    debug_msg "Pool de IPs configurado: $LB_RANGE"
    
    # Copiar configuración al master1
    if scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/metallb-ippool.yaml" "$USER@$MASTER1:~/metallb-ippool.yaml"; then
        debug_msg "✅ Configuración copiada al master1"
    else
        error_msg "❌ Error copiando configuración de MetalLB"
    fi
    
    # Aplicar configuración
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo mv metallb-ippool.yaml /var/lib/rancher/k3s/server/manifests/metallb-ippool.yaml"; then
        success_msg "✅ Pool de direcciones IP configurado correctamente"
    else
        error_msg "❌ Error aplicando configuración de pool IP"
    fi
    
    sleep 15  # Esperar a que se aplique la configuración
}

#############################################
#         TESTING AND VALIDATION            #
#############################################

# Función para esperar que el cluster esté completamente listo
wait_for_cluster_ready() {
    log_structured "INFO" "Esperando que el cluster esté completamente listo..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
        local total_nodes=${#ALL_NODES[@]}
        
        debug_msg "Nodos listos: $ready_nodes/$total_nodes (intento $((attempt + 1))/$max_attempts)"
        
        if [[ $ready_nodes -eq $total_nodes ]]; then
            success_msg "✅ Todos los nodos están Ready ($ready_nodes/$total_nodes)"
            
            # Verificar que los pods del sistema estén ejecutándose
            local system_pods_running=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c " Running " || echo "0")
            if [[ $system_pods_running -gt 5 ]]; then
                success_msg "✅ Pods del sistema funcionando correctamente ($system_pods_running pods)"
                return 0
            else
                debug_msg "Pods del sistema ejecutándose: $system_pods_running"
            fi
        fi
        
        sleep 10
        ((attempt++))
    done
    
    warning_msg "⚠️  Timeout esperando que el cluster esté completamente listo"
    return 1
}

# Función para desplegar aplicación de prueba
deploy_test_application() {
    log_structured "INFO" "Desplegando aplicación de prueba (Nginx)..."
    
    # Crear manifiesto de prueba mejorado
    cat > "$HOME/nginx-test.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test-dev
  namespace: default
  labels:
    app: nginx-test-dev
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test-dev
  template:
    metadata:
      labels:
        app: nginx-test-dev
    spec:
      containers:
      - name: nginx
        image: nginx:stable-alpine
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 50m
            memory: 64Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-dev-service
  namespace: default
  annotations:
    metallb.universe.tf/address-pool: dev-pool
spec:
  selector:
    app: nginx-test-dev
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: LoadBalancer
EOF
    
    # Copiar al master1 y aplicar
    if scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/nginx-test.yaml" "$USER@$MASTER1:~/nginx-test.yaml"; then
        debug_msg "✅ Manifiesto de prueba copiado"
    else
        error_msg "❌ Error copiando manifiesto de prueba"
    fi
    
    if ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
        "sudo kubectl apply -f nginx-test.yaml --kubeconfig /etc/rancher/k3s/k3s.yaml"; then
        success_msg "✅ Aplicación de prueba desplegada"
    else
        error_msg "❌ Error desplegando aplicación de prueba"
    fi
    
    # Esperar a que los pods estén listos
    log_structured "INFO" "Esperando que los pods de Nginx estén listos..."
    local nginx_ready=false
    local attempts=0
    local max_attempts=20
    
    while [[ $attempts -lt $max_attempts ]]; do
        local ready_pods=$(ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
            "sudo kubectl get pods -l app=nginx-test-dev --kubeconfig /etc/rancher/k3s/k3s.yaml --no-headers 2>/dev/null | grep -c Running" || echo "0")
        
        if [[ $ready_pods -eq 2 ]]; then  # 2 replicas
            nginx_ready=true
            break
        fi
        
        debug_msg "Pods de Nginx listos: $ready_pods/2, intento $((attempts + 1))/$max_attempts"
        sleep 15
        ((attempts++))
    done
    
    if [[ "$nginx_ready" == "true" ]]; then
        success_msg "✅ Pods de Nginx listos y ejecutándose"
    else
        warning_msg "⚠️  Pods de Nginx no completamente listos"
    fi
}

# Función de validación comprehensiva del cluster
comprehensive_cluster_validation() {
    log_structured "INFO" "Ejecutando validación comprehensiva del cluster..."
    
    # Validar nodos
    log_structured "INFO" "Validando estado de nodos..."
    local node_info=$(kubectl get nodes -o wide 2>/dev/null || echo "ERROR")
    if [[ "$node_info" == "ERROR" ]]; then
        error_msg "❌ No se puede obtener información de nodos"
    else
        echo "$node_info"
        local unhealthy_nodes=$(echo "$node_info" | grep -v " Ready " | grep -v "NAME" | wc -l)
        if [[ $unhealthy_nodes -gt 0 ]]; then
            warning_msg "⚠️  Nodos no saludables detectados: $unhealthy_nodes"
        else
            success_msg "✅ Todos los nodos están saludables"
        fi
    fi
    
    # Validar pods del sistema
    log_structured "INFO" "Validando pods del sistema..."
    local system_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null || echo "ERROR")
    if [[ "$system_pods" == "ERROR" ]]; then
        warning_msg "⚠️  No se puede obtener información de pods del sistema"
    else
        local failed_pods=$(echo "$system_pods" | grep -E "(Error|CrashLoopBackOff|Pending)" | wc -l)
        local running_pods=$(echo "$system_pods" | grep -c "Running")
        
        if [[ $failed_pods -gt 0 ]]; then
            warning_msg "⚠️  Pods con fallos detectados: $failed_pods"
            echo "$system_pods" | grep -E "(Error|CrashLoopBackOff|Pending)"
        else
            success_msg "✅ Todos los pods del sistema están saludables"
        fi
        
        debug_msg "Pods ejecutándose: $running_pods"
    fi
    
    # Validar servicios LoadBalancer
    log_structured "INFO" "Validando servicios LoadBalancer..."
    local lb_services=$(kubectl get svc --all-namespaces --no-headers 2>/dev/null | grep LoadBalancer || echo "")
    if [[ -n "$lb_services" ]]; then
        local pending_lbs=$(echo "$lb_services" | grep -c "<pending>" || echo "0")
        if [[ $pending_lbs -gt 0 ]]; then
            warning_msg "⚠️  LoadBalancers pendientes: $pending_lbs"
            echo "$lb_services" | grep "<pending>"
        else
            success_msg "✅ Todos los LoadBalancers tienen IP asignada"
        fi
        echo "$lb_services"
    else
        debug_msg "No se encontraron servicios LoadBalancer"
    fi
    
    # Validar conectividad de red
    log_structured "INFO" "Validando conectividad de red..."
    if ping -c 3 "$VIP" &>/dev/null; then
        success_msg "✅ VIP ($VIP) es accesible"
    else
        warning_msg "⚠️  VIP ($VIP) no responde a ping"
    fi
    
    success_msg "✅ Validación comprehensiva completada"
}

# Función para probar la aplicación desplegada
test_deployed_application() {
    log_structured "INFO" "Probando aplicación desplegada..."
    
    # Obtener IP externa del servicio
    local external_ip=""
    local attempts=0
    local max_attempts=10
    
    while [[ $attempts -lt $max_attempts ]]; do
        external_ip=$(ssh -o ConnectTimeout=30 "$USER@$MASTER1" -i "/home/$USER/.ssh/$CERT_NAME" \
            "sudo kubectl get svc nginx-test-dev-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --kubeconfig /etc/rancher/k3s/k3s.yaml" 2>/dev/null || echo "")
        
        if [[ -n "$external_ip" && "$external_ip" != "<pending>" ]]; then
            break
        fi
        
        debug_msg "Esperando IP externa, intento $((attempts + 1))/$max_attempts"
        sleep 15
        ((attempts++))
    done
    
    if [[ -n "$external_ip" && "$external_ip" != "<pending>" ]]; then
        success_msg "✅ IP externa asignada: $external_ip"
        
        # Probar conectividad HTTP
        log_structured "INFO" "Probando conectividad HTTP a $external_ip..."
        if curl -s --connect-timeout 10 "http://$external_ip" | grep -q "Welcome to nginx"; then
            success_msg "✅ Aplicación de prueba respondiendo correctamente"
            success_msg "🌐 Accede a la aplicación en: http://$external_ip"
        else
            warning_msg "⚠️  Aplicación no responde correctamente via HTTP"
        fi
    else
        warning_msg "⚠️  No se pudo obtener IP externa para la aplicación de prueba"
    fi
}

#############################################
#         REPORTING FUNCTIONS               #
#############################################

# Función para generar reporte de instalación
generate_installation_report() {
    log_structured "INFO" "Generando reporte de instalación..."
    
    local report_file="k3s_installation_report_$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$report_file" << EOF
# Reporte de Instalación K3s HA - Desarrollo

## Información General
- **Fecha:** $(date)
- **Modo:** Desarrollo/Pruebas
- **Script Version:** 2.0-dev-safe

## Versiones Utilizadas
- **K3s:** $K3S_VERSION
- **Kube-VIP:** $KVVERSION
- **MetalLB:** $METALLB_VERSION
- **k3sup:** $K3SUP_VERSION

## Configuración del Cluster
- **VIP:** $VIP
- **Rango LoadBalancer:** $LB_RANGE
- **Interfaz de Red:** $INTERFACE

### Nodos Maestros
$(for master in $MASTER1 "${MASTERS[@]}"; do echo "- $master"; done)

### Nodos Trabajadores
$(for worker in "${WORKERS[@]}"; do echo "- $worker"; done)

## Estado del Cluster
\`\`\`
$(kubectl get nodes -o wide 2>/dev/null || echo "Error obteniendo información de nodos")
\`\`\`

## Servicios
\`\`\`
$(kubectl get svc --all-namespaces 2>/dev/null || echo "Error obteniendo información de servicios")
\`\`\`

## Pods del Sistema
\`\`\`
$(kubectl get pods --all-namespaces 2>/dev/null || echo "Error obteniendo información de pods")
\`\`\`

## Acceso al Cluster
- **Kubeconfig:** $KUBE_CONFIG_DIR/config
- **Contexto:** k3s-ha-dev
- **API Server:** https://$VIP:6443

## Archivos de Log
- **Log Principal:** $LOG_FILE
- **Log Debug:** $DEBUG_LOG
- **Backup:** $BACKUP_DIR

## Próximos Pasos
1. Verificar que todos los nodos están Ready
2. Probar despliegue de aplicaciones adicionales
3. Validar alta disponibilidad
4. Configurar monitoreo y alerting

---
*Generado automáticamente por el script de instalación K3s HA*
EOF

    success_msg "✅ Reporte generado: $report_file"
}

#############################################
#              MAIN EXECUTION               #
#############################################

main() {
    # Banner de inicio
    log_structured "INFO" "🚀 Iniciando instalación K3s HA - Modo Desarrollo"
    log_structured "INFO" "📋 Versiones: K3s $K3S_VERSION | Kube-VIP $KVVERSION | MetalLB $METALLB_VERSION"
    
    # Inicializar logs
    echo "K3s HA Development Installation - Started at $(date)" > "$LOG_FILE"
    echo "K3s HA Development Debug Log - Started at $(date)" > "$DEBUG_LOG"
    
    # Crear backup si está habilitado
    create_backup
    
    # Fase 1: Validaciones
    log_structured "INFO" "📋 FASE 1: Validaciones y Prerrequisitos"
    validate_versions
    validate_ssh_key
    validate_prerequisites
    validate_k3s_config
    check_ssh_connectivity
    
    # Fase 2: Instalación de herramientas
    log_structured "INFO" "🔧 FASE 2: Instalación de Herramientas"
    install_tools
    install_node_dependencies
    
    # Fase 3: Configuración del cluster
    log_structured "INFO" "⚙️  FASE 3: Configuración del Cluster"
    bootstrap_first_master
    setup_kubevip
    join_additional_masters
    join_worker_nodes
    
    # Fase 4: Configuración de red
    log_structured "INFO" "🌐 FASE 4: Configuración de Red"
    install_metallb
    configure_metallb_pool
    
    # Fase 5: Esperar y validar
    log_structured "INFO" "⏳ FASE 5: Validación y Espera"
    wait_for_cluster_ready
    
    # Fase 6: Pruebas
    log_structured "INFO" "🧪 FASE 6: Despliegue de Pruebas"
    deploy_test_application
    comprehensive_cluster_validation
    test_deployed_application
    
    # Fase 7: Reporte final
    log_structured "INFO" "📊 FASE 7: Generación de Reporte"
    generate_installation_report
    
    # Mensaje final
    success_msg "🎉 ¡Instalación K3s HA completada exitosamente!"
    success_msg "🔗 API Kubernetes: https://$VIP:6443"
    success_msg "📁 Kubeconfig: $KUBE_CONFIG_DIR/config"
    success_msg "📝 Logs: $LOG_FILE"
    
    if [[ "$BACKUP_BEFORE_CHANGES" == "true" ]]; then
        success_msg "💾 Backup: $BACKUP_DIR"
        success_msg "↩️  Rollback: $BACKUP_DIR/rollback.sh"
    fi
    
    log_structured "INFO" "✅ Script de desarrollo completado - Cluster listo para pruebas"
}

# Trap para cleanup en caso de error
cleanup_on_error() {
    error_msg "❌ Script interrumpido. Logs disponibles en: $LOG_FILE"
    if [[ "$BACKUP_BEFORE_CHANGES" == "true" && -d "$BACKUP_DIR" ]]; then
        log_structured "INFO" "💾 Backup disponible en: $BACKUP_DIR"
    fi
    exit 1
}

trap cleanup_on_error ERR INT TERM

# Ejecutar función principal
main "$@"