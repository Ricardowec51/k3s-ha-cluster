# Camino a producción

Este cluster es un **ambiente de desarrollo y arquitectura de referencia**.
Corre en hardware doméstico y casi sin uso real.
El objetivo es que la arquitectura y la forma de implementarla sean las
que después se llevarán a un ambiente de **producción**.

Este documento lista qué se mantiene igual y qué hay que cambiar en ese paso.
Mantenerlo al día cada vez que se tome una decisión "de laboratorio".

Creado el 2026-11-23.

---

## 1. Lo que se lleva tal cual (patrones validados)

| Pieza | Qué está probado | Dónde |
|---|---|---|
| K3s HA | 3 masters con etcd (tolera perder 1), VIP de API con kube-vip, workers en hosts físicos distintos | `README.md` |
| Balanceo | MetalLB con pool de IPs propio | `README.md` |
| PostgreSQL | CloudNativePG, 3 instancias (1 primario + 2 réplicas) en 3 hosts, failover automático probado (2026-11-23) | `emprendedores-ltda/k8s/postgres-cnpg-cluster.yaml` |
| Mantenimiento | Rotación de hosts sin corte (`monthly-maintenance.sh prepare/restore`) | `mantenimiento-proxmox.md` |
| Respaldos | Varias capas, **verificadas** y con **aviso por correo**: dump diario de la BD, snapshots ZFS de PVCs, PBS semanal de VMs | `README.md` § Backups |
| Certificados | cert-manager con renovación automática | `README.md` |
| Arranque tras corte | Orden de encendido y dependencias documentadas | `energia-y-arranque.md` |

> Lección aprendida (jun→nov 2026): los respaldos de PBS fallaron 5 meses sin que nadie lo notara.
> En producción, **todo respaldo tiene restauración probada y alerta si falla o si no corre**.

---

## 2. Lo que hay que cambiar

### 2.1 Almacenamiento y respaldos — crítico
- [ ] **Hoy un solo TrueNAS** guarda los PVCs, el datastore de PBS y discos de VMs. Es un punto único de falla.
  Para producción hay dos opciones:
  - almacenamiento replicado (Ceph/Longhorn, o dos NAS con replicación);
  - o, como mínimo, PVCs sobre almacenamiento que no comparta equipo con los respaldos.
- [ ] **Respaldos fuera del equipo y fuera del sitio** (regla 3-2-1). Hoy los respaldos de PBS viven en el mismo TrueNAS.
  Para laboratorio está pendiente copiarlos al Synology DS1621+.
  En producción hace falta una copia fuera del sitio: nube o un PBS remoto con sync.
- [ ] **Restauración probada de forma periódica**, no solo `verify`: restaurar una VM y la BD en un entorno aparte.
- [ ] **Respaldo continuo de la BD** (WAL + base backup con barman/plugin de CNPG hacia object storage, con PITR).
  Hoy solo hay un dump diario.

### 2.2 Base de datos
- [ ] **Replicación síncrona**: al menos 1 réplica síncrona (`minSyncReplicas: 1`, `maxSyncReplicas: 1`), para no perder escrituras en un failover.
  Hoy es asíncrona.
- [ ] Usar `.spec.enablePDB` en lugar de la ventana de mantenimiento antigua.
  CNPG lo advierte al aplicar.
- [ ] Recursos (requests/limits) y parámetros de Postgres dimensionados según la carga real.

### 2.3 Configuración como código (GitOps)
- [ ] **Hoy hay cambios aplicados a mano** con `kubectl patch` o `helm --set` que no están en Git:
  - Rancher: hostname, IP y startupProbe;
  - Prometheus: `retentionSize` y PVC de 30 Gi;
  - anotaciones de MetalLB y otros.
  En producción **todo vive en Git** y se aplica desde ahí con Argo CD o Flux.
  El cluster debe poder reconstruirse desde cero con el repo.
- [ ] Values de Helm versionados para cada chart (Rancher, kube-prometheus-stack, CNPG, MetalLB, cert-manager, democratic-csi).
- [ ] Infraestructura de VMs reproducible (Terraform/OpenTofu o Ansible) en vez de crear VMs a mano.

### 2.4 Secretos
- [ ] Hoy hay Secrets de Kubernetes sin cifrar, y algunas contraseñas quedaron anotadas en texto plano.
  En producción:
  - Secrets cifrados en Git (SOPS o Sealed Secrets) o un gestor externo (Vault o External Secrets);
  - rotación de credenciales.
- [ ] La contraseña de aplicación de Gmail se comparte entre TrueNAS, Proxmox y PBS.
  En producción, usar un relay SMTP propio o una credencial por servicio.

### 2.5 Red, DNS y TLS
- [ ] Hoy los nombres son `*.sslip.io` con certificados internos.
  En producción: dominio propio, DNS real, certificados públicos (Let's Encrypt vía cert-manager) e Ingress con TLS.
- [ ] Separar redes: gestión (Proxmox/IPMI), almacenamiento (iSCSI/NFS), servicios y usuarios (VLANs).
  Hoy casi todo está en 192.168.1.0/24.
- [ ] Reglas de acceso: NetworkPolicies en el cluster y firewall entre redes.

### 2.6 Hardware y energía
- [ ] Hoy son mini-PCs y desktops: Minisforum MS-01, Dell con i5 serie T.
  Tienen límites térmicos (el DELL Gen 13 llega a 77–82 °C) y no tienen IPMI ni gestión remota.
  En producción: servidores con gestión fuera de banda (iDRAC/iLO/IPMI), fuentes y discos redundantes y monitoreo de hardware.
- [ ] UPS con apagado ordenado automático (NUT) y arranque automático confiable.
  Hoy el WOL no siempre despierta los hosts.
- [ ] Proxmox: **HA no está configurado**. Si un host se cae, sus VMs no se mueven solas.
  En producción hay que decidirlo: HA de Proxmox con almacenamiento compartido, o confiar solo en el HA de K3s, con workers sin estado.

### 2.7 Observabilidad y alertas
- [ ] Grafana es sin estado y tiene 2 réplicas, cada una con su propia SQLite.
  Hay que darle una BD persistente y dashboards como código.
- [ ] Prometheus: definir retención y almacenamiento según requisitos y llevarlo a Helm (ver 2.3).
- [ ] Alertmanager con un destino real (correo, Telegram o Slack) para nodos caídos, disco lleno, BD sin réplica, respaldo fallido y certificados por vencer.
- [ ] Logs centralizados (Loki o similar) y monitoreo externo de los servicios públicos.

### 2.8 Seguridad y operación
- [ ] Usuarios y roles: no usar `root@pam` ni el admin por defecto en el día a día; RBAC en K3s y Rancher.
- [ ] Actualizaciones con ambiente de pruebas: probar primero en desarrollo (este cluster) y luego en producción.
- [ ] Runbooks de incidentes y de restauración: ampliar `energia-y-arranque.md` y `mantenimiento-proxmox.md`.
- [ ] Requisitos del negocio: definir RPO/RTO (cuánto dato y cuánto tiempo se puede perder).
  De eso depende el resto del diseño.

---

## 3. Decisiones de laboratorio tomadas a propósito

Están bien para desarrollo. Hay que revisarlas antes de pasar a producción.

| Fecha | Decisión | Por qué en desarrollo | En producción |
|---|---|---|---|
| 2026-11-22 | Turbo desactivado y governor `powersave` en DELL/DELL1 | Temperatura | Hardware con refrigeración adecuada |
| 2026-11-23 | DELL (Gen 13) vacío en standby; todo en DELL1 (Gen 11) | DELL calienta | Capacidad N+1 real |
| 2026-11-23 | Disco de worker-02 en ZFS local de msa (antes NFS) | Evitar el iowait de NFS; los workers no guardan estado | Igual: workers sin estado, disco local |
| 2026-11-23 | Postgres 3 instancias, replicación asíncrona | Carga casi nula | Al menos 1 réplica síncrona (2.2) |
| 2026-11-23 | BIOS AC Recovery = "Last power state" | Así se configuran todas las máquinas | Revisar junto con UPS/NUT (2.6) |
