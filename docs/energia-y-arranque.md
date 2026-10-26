# Energía: apagado y arranque ordenado

Runbook para apagar y volver a encender toda la infraestructura (cluster K3s, hosts
Proxmox y TrueNAS) sin dejar el cluster trabado, y qué hacer después de un corte de luz.

> Creado el 2026-10-18 tras el corte de luz del 2026-10-17; actualizado el 2026-10-26 tras el segundo corte (procedimiento con baterías + postmortem). Script: [`scripts/utils/k3s-energia.sh`](../scripts/utils/k3s-energia.sh)
> (instalado como `~/bin/k3s-energia` en el Mac mini M4 Pro, 192.168.1.201).

---

## Resumen rápido

```bash
k3s-energia estado                    # equipos, quórum, nodos, Postgres, pods, servicios
k3s-energia apagar --dry-run          # ver qué haría
k3s-energia apagar                    # apagado completo (pide escribir APAGAR)
k3s-energia apagar --solo-cluster     # solo VMs del cluster; hosts y TrueNAS quedan arriba
k3s-energia arrancar                  # WOL + arranque ordenado + reparaciones
k3s-energia preparar-host <ip>        # dejar listo un host Proxmox nuevo
```

Logs de cada corrida: `~/Library/Logs/k3s-energia/`.

---

## 🔋 Corte de luz con baterías: cuándo y cómo apagar

> Contexto (oct-2026): cortes de energía frecuentes a nivel país; las baterías duran ~3 h.
> Si se acaban con todo encendido, el apagado es brusco y la recuperación cuesta más
> (pods trabados, discos de VMs sobre NFS, posible daño de filesystem: ver postmortems).

**Requisitos para que el procedimiento funcione**

- En baterías tienen que estar: **TrueNAS, DELL, msa, msn2, el switch/router y el Mac mini
  (192.168.1.201)**, que es desde donde corre el script.
  (Respaldo: paneles solares + baterías, ~3 h. Confirmado por Ricardo el 2026-10-26.)
- **Tormenta eléctrica:** también es motivo para apagar preventivamente: usar el mismo
  `k3s-energia apagar`, no el botón de los equipos.
- El apagado completo tarda **~15 min normalmente y 30 min en el peor caso**
  (Postgres 5 + workers 3 + masters 2 + resto de VMs 3 + hosts 5 + TrueNAS 10).

**Cuándo apagar**

| Tiempo sin luz | Acción |
|---|---|
| 0–60 min | Nada. Vigilar el nivel de batería. |
| **60–90 min** | **Si no hay fecha de regreso de la luz: apagar** (deja ≥1 h de margen). |
| Batería < 40 % o anuncio de corte largo | Apagar ya, sin esperar. |

La batería rinde menos con carga alta y con la edad. Mejor apagar de más que de menos.

**Cómo apagar (desde el Mac mini)**

```bash
k3s-energia estado              # 1. foto del estado antes de apagar (queda en el log)
k3s-energia apagar --dry-run    # 2. opcional: ver qué va a hacer
k3s-energia apagar              # 3. escribir APAGAR cuando lo pida
```

Orden: hiberna Postgres → workers → masters → resto de VMs/CTs → hosts Proxmox →
**TrueNAS al final**. Cuando el script termina, se puede apagar el Mac mini.

> La regla "TrueNAS nunca se apaga" vale para la operación normal. En un corte con
> baterías, TrueNAS **sí** se apaga, siempre como último paso.

**Si el Mac mini no está disponible (a mano, en este orden)**

1. `kubectl -n contactos annotate cluster.postgresql.cnpg.io postgres-contactos cnpg.io/hibernation=on --overwrite`
   y esperar a que desaparezcan los pods `postgres-contactos-*`.
2. En la web de Proxmox (https://192.168.1.7:8006): *Shutdown* de los workers 3005, 3006 y 3007,
   y después de los masters 3001, 3002 y 3003.
3. *Shutdown* de cada host (DELL, msa y msn2): apaga ordenadamente el resto de sus VMs.
4. TrueNAS: web → *Power* → *Shut Down*.

**Al volver la luz**

1. Esperar **10–15 min de luz estable** antes de encender nada: en estos cortes la luz suele
   ir y venir, y un segundo corte en pleno arranque es lo peor.
2. Encender **TrueNAS primero** y después DELL, msa y msn2. El WOL **no** funciona tras un corte
   total (comprobado el 2026-10-26), hay que encenderlos a mano hasta que la BIOS tenga
   *Restore on AC Power Loss*.
3. `k3s-energia arrancar`: es idempotente y repara lo típico. Al final muestra el `estado`.
4. Si queda algo raro, revisar la tabla de trabas en los postmortems de abajo.

---

## Dependencias de arranque

```
TrueNAS (192.168.1.100)  ── NFS/iSCSI ──►  discos de los workers K3s (storage PVE "TRUENAS")
        │                                  volúmenes de los pods (democratic-csi)
        ▼
Hosts Proxmox (DELL, msa, msn2)  ── quórum PVE (3 de 4 votos; nuc10 cuenta como miembro apagado)
        │
        ▼
Masters K3s (disco local)  →  Workers K3s (disco en TrueNAS)  →  pods
                                                                  │
                                       democratic-csi listo  ─────┤
                                       Postgres (CNPG)  ──────────┴─►  apps (contactos, factuscan…)
```

**Regla:** TrueNAS es lo primero en encenderse y lo último en apagarse.

---

## Apagado (`k3s-energia apagar`)

| Paso | Qué hace | Por qué |
|---|---|---|
| 1 | Hiberna Postgres (`cnpg.io/hibernation=on`) | Apagado limpio de la base; CNPG conserva los PVCs |
| 2 | `qm shutdown` de los workers (180 s, luego forzado) | Sin drain: evita la avalancha de pods reubicándose |
| 3 | `qm shutdown` de los masters (120 s, luego forzado) | etcd se apaga junto |
| 4 | Apaga el resto de VMs y CTs de cada host | npm, n8n, Tailscale, OpenClaw, Dockershim, k3-admin, scanopy… |
| 5 | `systemctl poweroff` de los hosts Proxmox | Espera a que dejen de responder |
| 6 | `midclt call system.shutdown` en TrueNAS | Al final, cuando nadie lo usa |

`--solo-cluster` hace solo los pasos 1–3.

## Arranque (`k3s-energia arrancar`)

| Paso | Qué hace |
|---|---|
| 1 | WOL a TrueNAS (**primero**) y espera NFS (2049) + iSCSI (3260) |
| 2 | WOL a los hosts Proxmox y espera SSH |
| 3 | Espera quórum Proxmox y storage `TRUENAS` activo en cada host |
| 4 | Arranca masters (si no arrancaron solos) y espera la API + 3 masters Ready |
| 5 | Arranca workers y espera 6 nodos Ready |
| 6 | Arranca las VMs con `onboot=1` que hayan quedado detenidas |
| 7 | `rollout restart` de los controladores democratic-csi y borra leases de líder huérfanos |
| 8 | Borrado forzado de pods en `Terminating` / `Unknown` de antes del apagado |
| 9 | Despierta Postgres (`hibernation=off`) y espera todas las instancias listas |
| 10 | `rollout restart` de los Deployments en `CrashLoopBackOff` / `Error` |
| — | Muestra `estado` (incluye prueba TCP de cada LoadBalancer) |

Si un equipo no despierta por WOL, el script avisa: encenderlo a mano y volver a correr
`k3s-energia arrancar` (es idempotente: lo que ya está arriba lo salta).

---

## Wake-on-LAN

| Equipo | IP | NIC | MAC | WOL |
|---|---|---|---|---|
| TrueNAS | 192.168.1.100 (en enp2s0f1) | **enp0s31f6** (I219-V 1G integrado, sin IP) | `1c:1b:0d:0b:ac:a1` | g, persistente (POSTINIT) |
| DELL | 192.168.1.7 | enx6c1ff756f32b (USB r8152) | `6c:1f:f7:56:f3:2b` | g, persistente (`wol-vmbr0.service`) ⚠️ USB: probar desde apagado total |
| msa | 192.168.1.143 | enp90s0 (igc) | `58:47:ca:7c:23:79` | g, persistente (`wol-vmbr0.service`) |
| msn2 | 192.168.1.86 | enp87s0 (igc) | `58:47:ca:7c:6b:cc` | g, persistente (`wol-vmbr0.service`) |

El magic packet se envía desde el Mac por broadcast UDP/9 a `192.168.1.255`.

**Además, en la BIOS de cada equipo:** Wake-on-LAN / PCIe PME = On, ErP / Deep Sleep = Off.
Recomendado también *Restore on AC Power Loss = Power On*, para que se enciendan solos al volver la luz.

---

## Configuración aplicada fuera del script

### Hosts Proxmox (DELL, msa, msn2) — vía `k3s-energia preparar-host <ip>`

- **`/usr/local/sbin/esperar-truenas`** + drop-in
  **`/etc/systemd/system/pve-guests.service.d/esperar-truenas.conf`**
  (`ExecStartPre=-/usr/local/sbin/esperar-truenas`): antes de que `pve-guests` arranque las
  VMs con `onboot=1`, espera hasta 15 min a que el storage `TRUENAS` esté activo. Si no
  aparece, sigue igual para que al menos arranquen las VMs con disco local.
  Aplica también cuando el host arranca solo (corte de luz), sin el script.
- **`/etc/systemd/system/wol-vmbr0.service`**: `ethtool -s <nic> wol g` en cada arranque.

### TrueNAS (25.10.6)

- **NIC LAN** = `enp2s0f1` (10G SFP+ Intel 82599ES) — **no soporta WOL**.
- **Puerto 1G integrado** `enp0s31f6`: cableado a la LAN el 2026-10-18 **solo para WOL**,
  **sin IP**. TrueNAS no permite una segunda IP de 192.168.1.0/24 en otra interfaz, y no hace falta.
- Init/Shutdown scripts:
  - id 1 `ip route replace default via 192.168.1.254 dev enp0s31f6` — **desactivado**
    (resto de cuando la `.100` estaba en el 1G; con el puerto cableado rompería la ruta por defecto).
  - id 2 `ethtool -s enp0s31f6 wol g` — POSTINIT, activo.
- Tunables sysctl: `net.ipv4.conf.{all,default}.arp_ignore=1` y `arp_announce=2`
  (evitan que un puerto conteste ARP por la IP del otro).

---

## Postmortem: corte de luz del 2026-10-17

**Qué pasó**

- ~06:00 corte de luz. Al volver, **ningún equipo se encendió solo**. El DELL se encendió a
  mano a las 07:24; msa, msn2 y TrueNAS recién el 2026-10-18 ~11:20.
- Con un solo host, Proxmox no tenía quórum (1 de 4) → no arrancó VMs.
- Al encender los hosts antes de que TrueNAS terminara de subir, los workers fallaron su
  arranque automático: `storage 'TRUENAS' is not online`. Los masters (disco local) sí arrancaron.

**Trabas durante la recuperación y su solución**

| Síntoma | Causa | Solución |
|---|---|---|
| worker-03 con load ~44 y ~4 % CPU; pods en `CreateContainerError: context deadline exceeded` | Primer worker en subir, recibió casi todos los pods; su disco está en NFS de TrueNAS → saturado de I/O | Se resolvió al subir los otros workers. El script arranca los workers juntos |
| VolumeAttachments `attached=false`, `timed out waiting for external-attacher` | El `external-attacher` del controlador iSCSI arrancó antes que el driver y quedó colgado; además había un **lease de líder** de un pod que ya no existía | `kubectl -n democratic-csi rollout restart deploy/democratic-csi-iscsi-controller` + `kubectl -n democratic-csi delete lease external-attacher-leader-org-democratic-csi-iscsi` |
| `postgres-contactos-2` y `prometheus-0` en `Terminating` indefinido | Pods de antes del corte en nodos reiniciados | `kubectl delete pod … --grace-period=0 --force` (los datos están en los PVC) |
| CNPG `Waiting for the instances to become active` | Lo anterior | Se recuperó solo al destrabar CSI y los pods: 2/2 healthy |
| Backends de contactos/factuscan en `CrashLoopBackOff` | La base estaba caída al arrancar | `kubectl rollout restart deploy/…` |

Todas estas reparaciones quedaron automatizadas en los pasos 7–10 de `arrancar`.

---

## Postmortem: apagado preventivo por tormenta eléctrica (2026-10-26)

**Qué pasó**

- 00:49–00:50: **Ricardo apagó a mano los 3 hosts Proxmox** como protección ante una tormenta con
  muchos rayos. Después hubo un corte de luz de ~2 h, que las baterías (solares, ~3 h) habrían
  cubierto. msn2 registró `systemd-logind: Power key pressed short` → `Powering off` (botón =
  apagado ordenado del host, pero **sin apagar antes el cluster**). El DELL se cortó de golpe (su
  último log es de las 00:50:03). **TrueNAS quedó encendido** (uptime desde el 2026-10-18); solo
  perdió el link de sus puertos 10G `enp1s0f0/f1` al apagarse los hosts.
- **Lección:** el apagado por botón deja pods trabados y el CSI sucio al volver. Para un apagado
  preventivo (tormenta, corte largo) usar `k3s-energia apagar`: ver la sección 🔋.
- 10:28 revisión: `k3s-energia estado` → TrueNAS ok, hosts sin respuesta (ARP `FAILED` también
  desde TrueNAS, así que estaban apagados de verdad y no era un problema de red del Mac).
- `k3s-energia arrancar` (primera corrida real) mandó WOL desde el Mac, repetido desde TrueNAS:
  **ningún host despertó en más de 5 min**. Se encendieron a mano a las ~10:43. (No es concluyente
  sobre el WOL: el DELL se cortó en seco y la NIC puede no quedar armada; probarlo en la ventana de mantenimiento.)
- Después, **todo arrancó solo**: el hook `esperar-truenas` funcionó, masters y workers subieron
  con `onboot` sin `qm start` manual, y el quórum y el storage TRUENAS quedaron OK en ~1 min.
- Postgres CNPG: sano al subir (primario `-2`, réplica en streaming con lag de 27 ms, `contactos`
  con sus 9 filas). El backup diario de las 00:00 corrió al recuperarse.

**Trabas y solución**

| Síntoma | Causa | Solución |
|---|---|---|
| WOL sin efecto en los 3 hosts | Probablemente ErP/Deep Sleep tras apagado por botón/corte (en el DELL, además, la NIC es USB) | Encender a mano. Solución definitiva: BIOS *Restore on AC Power Loss = On* |
| Paso 7 de `arrancar` trabado 10 min en "pods de nodo CSI listos" | En worker-03 los pods `democratic-csi-*-node` de antes del corte quedaron en `Unknown`; el DaemonSet no los reemplaza mientras existan y el borrado recién ocurría en el paso 8 | `kubectl -n democratic-csi delete pod <pod> --grace-period=0 --force`. **Corregido en el script:** el paso 7 ahora borra primero los pods CSI en `Unknown`/`Terminating` |
| worker-03 con load 20–30, `CreateContainer … context deadline exceeded`, `driver name org.democratic-csi.* not found` | Saturación de I/O: el disco qcow2 de worker-03 está en NFS de TrueNAS y pasa por la NIC USB del DELL. Igual que el 17-oct | Se normaliza sola en ~15 min. Ver pendiente "disco de worker-03" |
| uptime-kuma y registry en `ContainerCreating` con `Multi-Attach error` | El VolumeAttachment viejo (worker-03) seguía activo | Se resolvió solo al reiniciarse los controladores CSI (paso 7) |
| `prometheus-0` en `CrashLoopBackOff`: `panic: preallocate: no space left on device` | **PVC de 20 Gi lleno**: `retention=30d` sin `retentionSize`. El corte no lo causó, pero lo dejó en evidencia al reproducir el WAL | PVC ampliado en caliente a **30 Gi** y `retentionSize: 26GB` en el CR `Prometheus` → 64 % de uso. ⚠️ Ver pendientes (Helm) |
| factuscan-backend `.61:8000` no responde desde el Mac | Problema previo (ver "Problemas conocidos") | — |

**Comandos útiles que se usaron**

```bash
kubectl get pods -A --no-headers | grep -vE "Running|Completed"
kubectl -n democratic-csi get pods -o wide                      # ¿algún *-node-* en Unknown?
ssh rwagner@192.168.1.13 'uptime; cat /proc/pressure/io'        # presión de I/O en worker-03
kubectl -n monitoring logs prometheus-monitoring-kube-prometheus-prometheus-0 -c prometheus --previous
kubectl get clusters.postgresql.cnpg.io -A                      # Postgres sano
ssh root@192.168.1.86 'journalctl -b -1 -n 50'                  # por qué se apagó un host
```

---

## Problemas conocidos (no relacionados con el corte)

- **Rancher (`.29`)** no es accesible por su IP de LoadBalancer: esa IP la usa legítimamente
  un monitor Sense. Moverlo implica cambiar `server-url`, el ingress
  (`192.168.1.29.sslip.io`), el certificado y la configuración de Fleet; queda para una
  ventana planificada. (Uptime Kuma, que chocaba con un Ring en `.30`, se movió a `.33`
  el 2026-10-18 y la `.30` se excluyó del pool.)
- **factuscan-backend (`.61:8000`)** responde desde dentro del cluster pero no desde el Mac (en revisión; sigue igual el 2026-10-26).
- `TRUENAS-ISCSI`, `NFS_SHARE`, `NFS_SERVER` aparecen inactivos en Proxmox: apuntan a un
  portal viejo (`10.10.58.100`). Preexistente.

## Pendientes

- [ ] **Ventana de mantenimiento al sumar el DELL nuevo** (decidido el 2026-10-26: todo junto, para
      no apagar y verificar dos veces):
  - [ ] `k3s-energia apagar` real. Es la primera prueba del apagado; `arrancar` ya se probó en real el 2026-10-26.
  - [ ] BIOS de **DELL OptiPlex 7010** (F2 → *Power Management*): *AC Recovery = Power On*,
        *Deep Sleep Control = Disabled*, *Wake on LAN = LAN Only*.
  - [ ] BIOS de **msa y msn2** (Minisforum "Venus Series", BIOS 1.26; Supr → *Advanced*):
        *Restore on AC Power Loss = Power On* (o *State After G3 = S0*), *ErP = Disabled*.
  - [ ] BIOS de TrueNAS: igual, más WOL / PCIe PME on.
  - [ ] DELL nuevo: unir a Proxmox, `preparar-host`, `PVE_HOSTS`, BIOS. Considerar
        `pvecm delnode nuc10` para no contarlo en el quórum.
  - [ ] Probar: desenchufar un host unos segundos y ver que se encienda solo.
- [ ] **Prometheus fuera de Helm:** `retentionSize: 26GB` y el PVC de 30 Gi se aplicaron a mano. Antes
      del próximo `helm upgrade` de kube-prometheus-stack agregar a los values
      `prometheus.prometheusSpec.retentionSize: 26GB`; si no, Helm lo borra y el volumen se vuelve a llenar.
- [ ] Disco de worker-03: está en NFS (TrueNAS) a través de la NIC USB del DELL y se satura en
      cada arranque. Evaluar moverlo a un disco local del DELL nuevo o repartir la carga.
- [ ] Opcional: apagado automático desde el UPS (NUT), si el UPS tiene puerto USB/red.

## Agregar un host Proxmox nuevo

1. Unirlo al cluster Proxmox y montar el storage `TRUENAS`.
2. `k3s-energia preparar-host <ip>` (hook de espera a TrueNAS + WOL persistente).
3. Agregar `nombre:ip:mac` a `PVE_HOSTS` en el script (y en `~/bin/k3s-energia`).
4. Si aloja VMs del cluster, agregarlas a `MASTERS` / `WORKERS` (`vmid@ip_host`).
5. BIOS: WOL on, ErP off, Restore on AC Power Loss on.
