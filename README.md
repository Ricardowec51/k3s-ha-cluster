# K3s HA Cluster — Homelab

Cluster Kubernetes de alta disponibilidad basado en K3s, corriendo en red local `192.168.1.0/24`.

> **Estado:** Producción estable — última revisión completa 2026-09-21

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

> Masters 01 y 03 tienen 8 GB RAM. Uso observado: 65-75%. Funcional pero ajustado — candidatos a ampliar si se agregan workloads.

### Versiones

| Componente | Versión |
|---|---|
| K3s | v1.30.13+k3s1 |
| MetalLB | v0.14.9 |
| PostgreSQL (CNPG) | 17.2 |
| kube-prometheus-stack | 81.2.2 |

---

## Red

| Recurso | Valor |
|---|---|
| Red local | 192.168.1.0/24 |
| API server | https://192.168.1.21:6443 |
| MetalLB pool | 192.168.1.29 – 192.168.1.70 |
| Registry privado | http://192.168.1.64:5000 |
| Máquina de control | MacBook Pro M3 — 192.168.1.8 |

### IPs de servicios (LoadBalancer)

| IP | Servicio | Puerto |
|---|---|---|
| 192.168.1.29 | Rancher | 443 / 80 |
| 192.168.1.30 | Uptime Kuma | 3001 |
| 192.168.1.31 | Homepage | 80 |
| 192.168.1.53 | contactos / admin-panel | 80 |
| 192.168.1.54 | contactos / backend | 80 |
| 192.168.1.55 | contactos / postgres (CNPG) | 5432 |
| 192.168.1.56 | contactos / website | 80 |
| 192.168.1.57 | Prometheus | 9090 |
| 192.168.1.58 | Grafana | 80 |
| 192.168.1.59 | factuscan / frontend | 80 |
| 192.168.1.60 | contactos / pgAdmin | 80 |
| 192.168.1.61 | factuscan / backend | 8000 |
| 192.168.1.64 | Registry privado | 5000 |

---

## Infraestructura instalada

| Componente | Namespace | Descripción |
|---|---|---|
| MetalLB | metallb-system | Load balancer L2 |
| democratic-csi | democratic-csi | Storage iSCSI + NFS sobre TrueNAS (192.168.1.100) |
| cert-manager | cert-manager | Gestión de certificados TLS |
| CNPG | cnpg-system | CloudNativePG — operator para PostgreSQL |
| Prometheus + Grafana | monitoring | Stack de monitoreo (kube-prometheus-stack) |
| Uptime Kuma | monitoring-tools | Monitoreo de disponibilidad |
| Rancher | cattle-system | Gestión del cluster — instalado por separado |

> **Longhorn fue desinstalado el 2026-09-21** — no tenía volúmenes activos. Todo el storage usa democratic-csi sobre TrueNAS.

---

## Storage (TrueNAS — 192.168.1.100)

| PVC | Namespace | Tamaño | Tipo | Uso |
|---|---|---|---|---|
| postgres-contactos-1 | contactos | 50 Gi | iSCSI | BD primaria CNPG |
| postgres-contactos-2 | contactos | 50 Gi | iSCSI | Réplica CNPG |
| postgres-backups-truenas | contactos | 20 Gi | NFS | Backups diarios |
| pgadmin-data-truenas | contactos | 1 Gi | NFS | pgAdmin |
| factuscan-storage-iscsi | factuscan | 10 Gi | iSCSI | App factuscan |
| prometheus-db | monitoring | 20 Gi | iSCSI | Métricas Prometheus |
| uptime-kuma-pvc-iscsi | monitoring-tools | 4 Gi | iSCSI | Uptime Kuma |
| registry-data | registry | 30 Gi | iSCSI | Imágenes Docker |

**Total: 185 Gi**

### Storage classes

| Clase | Provisioner | Reclaim |
|---|---|---|
| truenas-iscsi | org.democratic-csi.iscsi | Retain |
| truenas-nfs | org.democratic-csi.nfs | Retain |
| local-path (default) | rancher.io/local-path | Delete |

> La política `Retain` significa que al borrar un PVC el PV queda en estado `Released` y **ocupa espacio en TrueNAS hasta que se borre manualmente**. Revisar PVs Released periódicamente con `kubectl get pv | grep Released`.

---

## Aplicaciones

### contactos

| Componente | Réplicas | IP | Puerto |
|---|---|---|---|
| website | 2 | 192.168.1.56 | 80 |
| backend | 2 | 192.168.1.54 | 80 |
| admin-panel | 2 | 192.168.1.53 | 80 |
| pgAdmin | 1 | 192.168.1.60 | 80 |
| PostgreSQL (CNPG) | 2 (1 primary + 1 replica) | 192.168.1.55 | 5432 |

BD: cluster CNPG `postgres-contactos` — primary en `postgres-contactos-1`, réplica en `postgres-contactos-2`.

### factuscan

| Componente | Réplicas | IP | Puerto |
|---|---|---|---|
| frontend | 2 | 192.168.1.59 | 80 |
| backend | 1 | 192.168.1.61 | 8000 |

> `factuscan` usa la misma BD CNPG que `contactos` vía servicio `factuscan-db` → `192.168.1.55:5432`.

### Otros

| App | Namespace | IP | Puerto |
|---|---|---|---|
| Homepage | homepage | 192.168.1.31 | 80 |
| Registry | registry | 192.168.1.64 | 5000 |

**Imágenes en registry:** `admin-panel`, `backend-contacto`, `factuscan-backend`, `factuscan-frontend`, `website-emprendedores`

---

## Backups

### PostgreSQL (contactos)

- **Schedule:** diario a las 02:00 UTC
- **Destino:** TrueNAS NFS → `/mnt/pool_1/k8s-nfs/pvc-8efee457.../`
- **Retención GFS:**
  - Diario: últimos 7 días
  - Mensual: último backup de cada mes cerrado
  - Anual: último backup de cada año cerrado
- **Manifiesto:** `configs/contactos/postgres-backup-cronjob.yaml`
- **Verificar:** `kubectl logs -n contactos job/<último-job>`

```bash
# Ver último job
kubectl get jobs -n contactos --sort-by=.metadata.creationTimestamp | tail -3
```

---

## Certificados

| Certificado | Gestión | Vence | Renovación |
|---|---|---|---|
| Rancher (tls-rancher-ingress) | cert-manager | 2026-11-06 | Auto — 2026-10-07 |
| CNPG CA / server / replication | CNPG interno | 2026-10-24 | Auto |

---

## Monitoreo

- **Prometheus:** `http://192.168.1.57:9090` — retención 30 días, storage persistente en TrueNAS
- **Grafana:** `http://192.168.1.58` — credenciales: `admin / admin`
- **Uptime Kuma:** `http://192.168.1.30:3001`

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

Todos los nodos tienen `/etc/rancher/k3s/registries.yaml` configurado para HTTP sin autenticación (red local).

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

## Manifiestos en repo

| Archivo | Descripción |
|---|---|
| `hosts.ini` | Inventario Ansible de todos los nodos |
| `configs/contactos/postgres-backup-cronjob.yaml` | CronJob de backup PostgreSQL con retención GFS |
| `configs/metallb/` | Configuración MetalLB |

---

## Historial de cambios

| Fecha | Cambio |
|---|---|
| 2026-09-19 | Reducción de workers (5 → 3), reparación de etcd, tuning térmico de nodos |
| 2026-09-19 | Instalación del registry privado (`192.168.1.64:5000`) |
| 2026-09-20 | Migración de máquina de trabajo: Mac Mini M4 → MacBook Pro M3 |
| 2026-09-21 | Actualización de scripts e IPs reales, `hosts.ini` al repo, registry configurado en todos los nodos |
| 2026-09-21 | Desinstalación de Longhorn (sin uso) — liberados ~1 TB en workers |
| 2026-09-21 | Prometheus: PVC 20Gi en TrueNAS + retención 30d (antes emptyDir + 1d) |
| 2026-09-21 | Backup PostgreSQL: retención GFS (7d diario + mensual + anual) + fix trap ERR |
| 2026-09-21 | Limpieza general: ~60 replicasets viejos, 3 jobs fallidos, 114Gi PVs huérfanos eliminados |
| 2026-09-21 | Scripts de deploy: eliminado kube-vip, MetalLB por kubectl directo, registry en todos los nodos |
