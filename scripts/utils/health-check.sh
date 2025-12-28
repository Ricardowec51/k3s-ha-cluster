#!/bin/bash
# Script de Health Check para Cluster K3s HA
echo "🏥 Verificando estado del cluster..."
echo "--- Nodos ---"
kubectl get nodes
echo "--- Pods Críticos ---"
kubectl get pods -n kube-system
echo "--- Almacenamiento ---"
kubectl get sc,pvc -A
echo "--- Servicios LoadBalancer ---"
kubectl get svc -A | grep LoadBalancer || echo "Sin LoadBalancers activos"
