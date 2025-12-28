# K3s High Availability Cluster Setup
Este repositorio contiene los scripts necesarios para desplegar un cluster de **K3s en Alta Disponibilidad (HA)** utilizando `k3sup`, `kube-vip` y `MetalLB`.

## 🚀 Instalación Rápida
Puedes descargar y ejecutar el instalador completo con un solo comando:

```bash
curl -fsSL https://raw.githubusercontent.com/Ricardowec51/k3s-ha-cluster/main/k3s_installer_complete.sh -o k3s_installer_complete.sh && chmod +x k3s_installer_complete.sh && ./k3s_installer_complete.sh
```

## 🛠️ Configuración
Antes de ejecutar, asegúrate de editar las variables al inicio del script `k3s_installer_complete.sh`:
- **USER**: Tu usuario con acceso SSH.
- **INTERFACE**: Interfaz de red de los nodos (ej: `ens18`).
- **MASTER1, 2, 3**: IPs de tus nodos maestros.
- **WORKER1, 2, 3**: IPs de tus nodos trabajadores.
- **VIP**: IP flotante para el acceso al API Server (HA).
- **LB_RANGE**: Rango de IPs para servicios externos (MetalLB).

## 📦 Contenido
- `k3s_installer_complete.sh`: Script principal de automatización.
- `scripts/utils/health-check.sh`: Verifica la salud del cluster.
- `scripts/utils/backup-cluster.sh`: Realiza un respaldo rápido de la configuración.

## 📋 Requisitos
- 3 VMs con Ubuntu 22.04/24.04 para Masters.
- Al menos 1 VM para Worker.
- Acceso SSH mediante llaves (sin contraseña) configurado entre el equipo que ejecuta el script y los nodos.
- `sudo` configurado sin contraseña en los nodos.
