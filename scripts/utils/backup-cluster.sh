#!/bin/bash
# Script de Backup para Cluster K3s
set -e
BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "📦 Realizando backup de configuraciones en $BACKUP_DIR..."
[ -f ~/.kube/config ] && cp ~/.kube/config "$BACKUP_DIR/kubeconfig"
kubectl get nodes -o wide > "$BACKUP_DIR/nodes_status.txt"
kubectl get svc -A > "$BACKUP_DIR/services_status.txt"
echo "✅ Backup completado."
