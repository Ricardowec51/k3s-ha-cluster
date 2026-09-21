# K3s HA Cluster — Homelab

Cluster Kubernetes de alta disponibilidad basado en K3s, corriendo en red local `192.168.1.0/24`.

---

## Topología

### Nodos

| Nodo | IP | Rol | RAM | OS |
|---|---|---|---|---|
| k3s-master-01 | 192.168.1.21 | control-plane, etcd, master | 8 GB | Ubuntu 24.04.3 LTS |
| k3s-master-02 | 192.168.1.22 | control-plane, etcd, master | 32 GB | Ubuntu 24.04.3 LTS |
| k3s-master-03 | 192.168.1.23 | control-plane, etcd, master | 8 GB | Ubuntu 24.04.3 LTS |
| k3s-worker-02 | 192.168.1.25 | worker | 32 GB | Ubuntu 24.04.3 LTS |
| k3s-worker-03 | 192.168.1.13 | worker | 16 GB | Ubuntu 24.04.3 LTS |
| k3s-worker-04 | 192.168.1.27 | worker | 32 GB | Ubuntu 24.04.3 LTS |

### Versiones

| Componente | Versión |
|---|---|
| K3s | v1.30.13+k3s1 |
| MetalLB | v0.14.9 |

---

## Red

| Recurso | Valor |
|---|---|
| Red local | 192.168.1.0/24 |
| API server | https://192.168.1.21:6443 |
| MetalLB pool | 192.168.1.29 – 192.168.1.70 |
| Registry privado | http://192.168.1.64:5000 |

### IPs de servicios (LoadBalancer)

| IP | Servicio | Puerto |
|---|---|---|
| 192.168.1.29 | Rancher | 443 / 80 |
| 192.168.1.30 | Uptime Kuma | 3001 |
| 192.168.1.31 | Homepage | 80 |
| 192.168.1.53 | contactos / admin-panel | 80 |
| 192.168.1.54 | contactos / backend | 80 |
| 192.168.1.55 | contactos / postgres | 5432 |
| 192.168.1.56 | contactos / website | 80 |
| 192.168.1.57 | Prometheus | 9090 |
| 192.168.1.58 | Grafana | 80 |
| 192.168.1.59 | factuscan / frontend | 80 |
| 192.168.1.60 | contactos / pgAdmin | 80 |
| 192.168.1.61 | factuscan / backend | 8000 |
| 192.168.1.63 | Longhorn UI | 80 |
| 192.168.1.64 | Registry privado | 5000 |

---

## Infraestructura instalada

| Componente | Namespace | Descripción |
|---|---|---|
| MetalLB | metallb-system | Load balancer L2 — reemplaza kube-vip |
| Longhorn | longhorn-system | Storage distribuido en workers |
| democratic-csi | democratic-csi | iSCSI + NFS |
| cert-manager | cert-manager | Gestión de certificados TLS |
| CNPG | cnpg-system | CloudNativePG — operator para PostgreSQL |
| Prometheus + Grafana | monitoring | Stack de monitoreo |
| Uptime Kuma | monitoring-tools | Monitoreo de disponibilidad |

> **Rancher** y **Longhorn** se instalan por separado, no mediante estos scripts.

---

## Aplicaciones

| Namespace | Componentes |
|---|---|
| contactos | backend, frontend, admin-panel, PostgreSQL (CNPG), pgAdmin, backup diario |
| factuscan | backend, frontend |
| homepage | Dashboard principal |
| registry | Registro privado de contenedores |

---

## Acceso

### Kubectl (desde MacBook Pro — máquina principal)

```bash
kubectl get nodes
```

Contexto activo: `k3s-homelab` en `~/.kube/config`.

### SSH a los nodos

```bash
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.21   # master-01
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.22   # master-02
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.23   # master-03
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.25   # worker-02
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.13   # worker-03
ssh -i ~/.ssh/id_rsa rwagner@192.168.1.27   # worker-04
```

### Registry privado

Todos los nodos tienen `/etc/rancher/k3s/registries.yaml` configurado para HTTP.

```bash
# Push desde Mac
docker tag mi-imagen 192.168.1.64:5000/mi-imagen
docker push 192.168.1.64:5000/mi-imagen
```

```yaml
# En manifiestos Kubernetes
image: 192.168.1.64:5000/mi-imagen
```

---

## Scripts de deployment

| Script | Uso |
|---|---|
| `scripts/production/k3s-deploy-C3.7-190325-1.sh` | Deploy completo en producción |
| `scripts/development/k3s_dev_test_script.sh` | Deploy con validaciones extendidas para pruebas |

### Requisitos previos

- SSH key `~/.ssh/id_rsa` autorizada en todos los nodos
- Usuario `rwagner` con `sudo` sin contraseña en los nodos Linux
- `k3sup` y `kubectl` instalados en la máquina de control

### Variables principales (ambos scripts)

```bash
MASTER1="192.168.1.21"
MASTER2="192.168.1.22"
MASTER3="192.168.1.23"
WORKER1="192.168.1.25"   # k3s-worker-02
WORKER2="192.168.1.13"   # k3s-worker-03
WORKER3="192.168.1.27"   # k3s-worker-04
VIP="192.168.1.50"
LB_RANGE="192.168.1.29-192.168.1.70"
K3S_VERSION="v1.30.13+k3s1"
```

---

## Historial de cambios

| Fecha | Cambio |
|---|---|
| 2026-09-19 | Reducción de workers (5 → 3), reparación de etcd, tuning térmico de nodos |
| 2026-09-19 | Instalación del registry privado (`192.168.1.64:5000`) |
| 2026-09-20 | Migración de máquina de trabajo: Mac Mini M4 → MacBook Pro M3 |
| 2026-09-21 | Actualización de scripts e IPs reales, `hosts.ini` al repo, registry configurado en todos los nodos |
