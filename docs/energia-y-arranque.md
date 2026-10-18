# Energía: apagado y arranque ordenado

Runbook para apagar y volver a encender toda la infraestructura (cluster K3s, hosts
Proxmox y TrueNAS) sin dejar el cluster trabado, y qué hacer después de un corte de luz.

> Creado el 2026-10-18 tras el corte de luz del 2026-10-17. Script: [`scripts/utils/k3s-energia.sh`](../scripts/utils/k3s-energia.sh)
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

## Problemas conocidos (no relacionados con el corte)

- **Rancher (`.29`)** no es accesible por su IP de LoadBalancer: esa IP la usa legítimamente
  un monitor Sense. Moverlo implica cambiar `server-url`, el ingress
  (`192.168.1.29.sslip.io`), el certificado y la configuración de Fleet; queda para una
  ventana planificada. (Uptime Kuma, que chocaba con un Ring en `.30`, se movió a `.33`
  el 2026-10-18 y la `.30` se excluyó del pool.)
- **factuscan-backend (`.61:8000`)** responde desde dentro del cluster pero no desde el Mac (en revisión).
- `TRUENAS-ISCSI`, `NFS_SHARE`, `NFS_SERVER` aparecen inactivos en Proxmox: apuntan a un
  portal viejo (`10.10.58.100`). Preexistente.

## Pendientes

- [ ] BIOS de TrueNAS: WOL / PCIe PME on, ErP off. Probar WOL real.
- [ ] Probar WOL del DELL desde apagado total (NIC USB).
- [ ] *Restore on AC Power Loss* en todos los equipos.
- [ ] Probar el ciclo completo `apagar` → `arrancar` en una ventana tranquila (hasta ahora solo `--dry-run`).
- [ ] DELL nuevo (semana del 2026-10-19): agregar a `PVE_HOSTS` y correr `preparar-host`.
      Considerar sacar nuc10 del cluster Proxmox (`pvecm delnode nuc10`) para no contarlo en el quórum.

## Agregar un host Proxmox nuevo

1. Unirlo al cluster Proxmox y montar el storage `TRUENAS`.
2. `k3s-energia preparar-host <ip>` (hook de espera a TrueNAS + WOL persistente).
3. Agregar `nombre:ip:mac` a `PVE_HOSTS` en el script (y en `~/bin/k3s-energia`).
4. Si aloja VMs del cluster, agregarlas a `MASTERS` / `WORKERS` (`vmid@ip_host`).
5. BIOS: WOL on, ErP off, Restore on AC Power Loss on.
