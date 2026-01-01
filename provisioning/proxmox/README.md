# Proxmox Infrastructure as Code (IaC) - K3s Deployment

Este módulo permite la creación automatizada de nodos (Master y Worker) en un clúster de Proxmox optimizados para la instalación de K3s.

---

## 🇺🇸 English Version

This module enables automated provisioning of nodes (Masters and Workers) within a Proxmox cluster, specifically optimized for K3s installation.

### 🚀 Quick Start (One-Liner)

If you have Ansible installed, you can download and run the deployment wizard with this command:

```bash
curl -L -O https://raw.githubusercontent.com/Ricardowec51/k3s-ha-cluster/main/provisioning/proxmox/deploy_node_interactive.sh && \
curl -L -O https://raw.githubusercontent.com/Ricardowec51/k3s-ha-cluster/main/provisioning/proxmox/deploy_single_node.yml && \
chmod +x deploy_node_interactive.sh && ./deploy_node_interactive.sh
```

### Module Contents

- **`deploy_node_interactive.sh`**: Interactive "God Mode" script that validates network, IDs, and storage before deploying.
- **`deploy_single_node.yml`**: Ansible playbook that handles cloning and sequential Cloud-Init injection.
- **`deploy_k3s_current_config.sh`**: Quick-execution script with the last validated configuration (Masters 1-3, Workers 1-5).

### Prerequisites

1. **Ansible installed** on your local machine.
2. **Proxmox Collection**: `ansible-galaxy collection install community.general`.
3. **SSH Access**: Configured SSH key and root access to the Proxmox node.
4. **Python Dependencies**: `pip install proxmoxer requests`.

### How to use the Interactive Script

1. Enter the directory:
   ```bash
   cd provisioning/proxmox
   ```
2. Run the wizard:
   ```bash
   ./deploy_node_interactive.sh
   ```

### Technical Features

- **Real-Time Validation**: Queries the Proxmox API to verify node and storage availability.
- **Collision Detection**: Checks IPs via Ping and VM IDs via API before starting.
- **Triple-Stage Deployment**: Clone -> Hardware Config -> Cloud-Init Fix -> Start (Guarantees static IP).
- **Auto-Bootstrap**: Capable of downloading the official Ubuntu 24.04 image and generating Template 9000 automatically.

---

## 🇪🇸 Versión en Español

Infraestructura como Código (IaC) para la creación automatizada de nodos en Proxmox.

### 🚀 Inicio Rápido (One-Liner)

```bash
curl -L -O https://raw.githubusercontent.com/Ricardowec51/k3s-ha-cluster/main/provisioning/proxmox/deploy_node_interactive.sh && \
curl -L -O https://raw.githubusercontent.com/Ricardowec51/k3s-ha-cluster/main/provisioning/proxmox/deploy_single_node.yml && \
chmod +x deploy_node_interactive.sh && ./deploy_node_interactive.sh
```

### Contenido del Módulo

- **`deploy_node_interactive.sh`**: Script interactivo con validación total.
- **`deploy_single_node.yml`**: Playbook de Ansible para clonado y Cloud-Init.
- **`deploy_k3s_current_config.sh`**: Script de ejecución rápida pre-configurado.

### Requisitos Previos

1. **Ansible instalado**.
2. **Colección Proxmox** instalada.
3. **Acceso SSH root** a Proxmox.
4. **Dependencias de Python** (`proxmoxer`, `requests`).

---
*Developed for the k3s-ha-cluster project*
