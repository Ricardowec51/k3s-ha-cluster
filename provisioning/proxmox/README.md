# Infraestructura como Código (IaC) para Proxmox - K3s Deployment

Este módulo permite la creación automatizada de nodos (Master y Worker) en un clúster de Proxmox optimizados para la instalación de K3s.

## Contenido del Módulo

- **`deploy_node_interactive.sh`**: Script "God Mode" interactivo que valida red, IDs y almacenamiento antes de desplegar.
- **`deploy_single_node.yml`**: Playbook de Ansible que realiza el clonado y la inyección secuencial de Cloud-Init.
- **`deploy_k3s_current_config.sh`**: Script de ejecución rápida con la última configuración validada (Masters 1-3, Workers 1-5).

## Requisitos Previos

1. **Ansible instalado** en la máquina local.
2. **Colección Proxmox**: `ansible-galaxy collection install community.general`.
3. **Acceso SSH**: Clave SSH configurada y acceso root al nodo Proxmox.
4. **Dependencias Python**: `pip install proxmoxer requests`.

## Uso del Script Interactivo

1. Entra al directorio:
   ```bash
   cd provisioning/proxmox
   ```
2. Ejecuta el asistente:
   ```bash
   ./deploy_node_interactive.sh
   ```

## Características Técnicas

- **Validación Real-Time**: Consulta el API de Proxmox para verificar la existencia de nodos y storages.
- **Detección de Colisiones**: Verifica IPs vía Ping e IDs de VM vía API antes de iniciar.
- **Triple-Stage Deployment**: Clone -> Hardware Config -> Cloud-Init Fix -> Start (Garantiza IP estática).
- **Auto-Bootstrap**: Capacidad de descargar la imagen oficial de Ubuntu 24.04 y generar la Template 9000 automáticamente.

---
*Desarrollado para el proyecto k3s-ha-cluster*
