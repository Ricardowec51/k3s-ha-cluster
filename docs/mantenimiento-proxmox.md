# Mantenimiento de hosts Proxmox (actualización y reinicio en rotación)

Runbook para actualizar Proxmox y reiniciar los hosts (DELL1, msa, msn2; DELL vacío) **sin apagar el
cluster K3s**: un host a la vez, vaciando antes su worker y moviendo el primario de
Postgres si está ahí.

> Creado el 2026-11-06 tras la actualización al kernel 7.0.14-28 (pve 9.2.26).
> Script: [`scripts/utils/monthly-maintenance.sh`](../scripts/utils/monthly-maintenance.sh).
> Para apagar TODO (corte de luz, tormenta) se usa otro runbook: [`energia-y-arranque.md`](energia-y-arranque.md).

---

## Resumen rápido

```bash
S=/Volumes/Externo/k3s-ha-cluster/scripts/utils/monthly-maintenance.sh
$S status                    # reparto host→nodos, nodos, etcd, quórum Proxmox, pods
$S prepare <host> --dry-run  # qué haría, sin cambiar nada
$S prepare <host>            # chequeos + switchover de Postgres si aplica + cordon/drain del worker
ssh root@<ip-host> 'nohup systemctl reboot >/dev/null 2>&1 &'
$S restore <host>            # espera nodos Ready + uncordon + verifica etcd y pods
# esperar 15 min y repetir con el siguiente host
```

Hosts: **DELL1** 192.168.1.80 · **msa** 192.168.1.143 · **msn2** 192.168.1.86 · **DELL** 192.168.1.7
(vacío desde el 2026-11-22: se actualiza y reinicia sin `prepare`/`restore`).

---

## Por qué en rotación y no apagando el cluster

- Cada host tiene **1 master + 1 worker** (DELL1: master-01 + worker-03; msa: master-02 +
  worker-02; msn2: master-03 + worker-04). Con un host abajo quedan 2 de 3 masters: etcd
  mantiene quórum y los servicios siguen en los otros 2 workers.
- Los arranques en frío del cluster completo (17-oct, 26-oct, 03-nov) dejaron pods CSI
  trabados, pods en `Terminating` y nodos saturados. Reiniciar un host a la vez evita eso:
  el resto del cluster está sano y absorbe la carga.
- Resultado del 2026-11-06: los 3 hosts actualizados sin que el cluster se apagara; los
  servicios solo tuvieron cortes de segundos al moverse los pods.

---

## Antes de empezar

1. **Actualizar paquetes** en cada host (puede hacerse en todos antes de reiniciar ninguno):
   ```bash
   apt update && apt dist-upgrade
   ```
2. **Ver si hace falta reiniciar** (kernel en uso vs. el más nuevo instalado):
   ```bash
   for ip in 192.168.1.80 192.168.1.7 192.168.1.143 192.168.1.86; do
     ssh root@$ip 'echo "$(hostname): corre $(uname -r) | instalado $(ls /boot/vmlinuz-* | sed "s#.*/vmlinuz-##" | sort -V | tail -1)"'
   done
   ```
3. **`$S status`** debe dar: 6 nodos Ready, `etcd ok`, `Quorate: Yes` y sin pods con problemas.
4. **Elegir el orden:** el host con el primario de Postgres va **al final** (así se mueve una
   sola vez). Ver dónde está:
   ```bash
   kubectl -n contactos get pod -l cnpg.io/instanceRole=primary -o wide
   ```
5. **No migrar ni arrancar VMs durante la ventana** (ver "Quórum de Proxmox" abajo).

---

## Procedimiento por host

1. `$S prepare <host>`
   - Exige: nodos Ready, etcd ok, **ningún pod con problemas**, Proxmox con quórum y que
     los otros hosts lleven ≥ 15 min encendidos.
   - Si el primario de Postgres está en el worker de ese host, hace el switchover a la
     réplica (el PDB del primario bloquearía el drain).
   - `cordon` + `drain` del worker. El master no se vacía (sus pods son DaemonSets).
2. **Reiniciar el host:** `ssh root@<ip> 'nohup systemctl reboot >/dev/null 2>&1 &'`
   (o desde la UI de Proxmox). Tarda ~2 min en apagar (Proxmox apaga las VMs en orden) y
   unos minutos en volver.
3. `$S restore <host>`: espera hasta 15 min a que sus nodos estén Ready, hace `uncordon`
   y verifica etcd y pods.
4. **Verificar el host** (ver tabla siguiente).
5. **Esperar 15 min** antes del siguiente host (el `prepare` siguiente lo exige).

### Verificaciones después de cada host

| Qué | Comando (en el host) | Esperado |
|---|---|---|
| Kernel nuevo | `uname -r` | El más nuevo instalado |
| VMs arriba | `qm list` | Todas `running` |
| no-turbo (msa, msn2 y DELL; en DELL también governor `powersave`) | `systemctl is-active no-turbo; cat /sys/devices/system/cpu/intel_pstate/no_turbo` | `active` y `1` |
| Postgres | `kubectl -n contactos get clusters.postgresql.cnpg.io` | `2 2 Cluster in healthy state` |
| Servicios | `k3s-energia estado` (sección Servicios) | Todos ✔ |

---

## Qué se cae en cada host (además de su master y su worker)

| Host | VMs / CTs | Efecto mientras está abajo |
|---|---|---|
| DELL1 | PBS (100), k3-admin (1102) | Sin backups de PBS unos minutos |
| DELL | (ninguna desde el 2026-11-22) | Nada; solo baja a 3 de 4 votos de Proxmox |
| msa | Server24Tailscale (104), OpenClaw20 (881) | **Sin acceso remoto por Tailscale** |
| msn2 | VM-N8N (444), Dockershim (770), npm (7771), CT scanopy (102) | Sin n8n ni proxy inverso unos minutos |

---

## Problemas conocidos y qué hacer

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `prepare` se detiene: "Hay pods con problemas" | Cualquier pod no-Running lo bloquea (2026-11-06: un Homepage en `ImagePullBackOff`) | Arreglarlo o recrearlo (`kubectl delete pod`) si es sin estado; luego repetir `prepare` |
| Tras volver un host, pods CSI de su worker en `CrashLoopBackOff`; Postgres o pgAdmin en `Init:0/1` con `Multi-Attach` | El driver democratic-csi del worker tarda en registrarse | Esperar ~10 min: se resolvió solo el 2026-11-06. Si no, borrar esos pods CSI node para que se recreen |
| Postgres `1/2` un rato tras el switchover | La réplica se recrea en otro worker | Esperar a `Cluster in healthy state` antes del siguiente host |
| msa arranca con el kernel anterior | Servicio `kexec-pve` (ver abajo) | Desactivado desde el 2026-11-06; si reaparece, ver la sección de msa |
| Proxmox muestra 3 de 4 votos | Un host está reiniciando | Normal: 3 de 4 = quórum; vuelve a 4 al regresar |

### Quórum de Proxmox

Desde el 2026-11-22 el cluster MS-01 tiene 4 nodos vivos (DELL1, DELL, msa, msn2); nuc10 y
BOSC se eliminaron. Con un host apagado quedan 3 de 4 = **quórum**, así que Proxmox sigue
operativo. Antes (hasta el 2026-11-22) nuc10 muerta seguía contando y un host abajo dejaba el
cluster sin quórum. Si se apagan **dos** hosts a la vez se pierde el quórum: no hacerlo.

### msa y `kexec-pve`

msa tenía un servicio propio, `/etc/systemd/system/kexec-pve.service` (creado en nov-2025),
que al arrancar cargaba en memoria `/boot/pve/vmlinuz` para que el siguiente reinicio
saltara BIOS y GRUB (msa volvía en ~10 s). Efecto: el siguiente reinicio arrancaba **el
kernel que había en el arranque anterior**, así que un kernel recién instalado necesitaba
**dos reinicios** (pasó en sep-2026 con el -11 y el 2026-11-06 con el -17).

- **2026-11-06: desactivado** (`systemctl disable kexec-pve` + `kexec -u`). El archivo se
  conservó. msa reinicia ahora por BIOS/GRUB como los otros hosts.
- El primer reinicio de msa sin kexec conviene hacerlo **con acceso físico**: no se sabe
  desde cuándo no arranca por la BIOS.
- Revertir: `systemctl enable --now kexec-pve` (y volver a reiniciar dos veces tras cada
  kernel nuevo).

---

## Registro de corridas

| Fecha | Kernel | Orden | Notas |
|---|---|---|---|
| 2026-11-22 | 7.0.14-28 → 7.0.14-30 (pve 9.2.32) | DELL → msn2 → msa | Antes: nuc10 y BOSC eliminados del cluster PVE y DELL1 (.80) unido. msa arrancó bien por BIOS al primer reinicio (sin `kexec-pve`). Primario de Postgres pasó a `postgres-contactos-1`. pgAdmin ~3 min sin responder (repull de imagen). Después: master-01, worker-03, PBS y k3-admin migrados en caliente de DELL a DELL1 (DELL calentaba); k3-admin bajado a 4 vCPU |
| 2026-11-06 | 7.0.14-17 → 7.0.14-28 (pve 9.2.26) | DELL → msa (×2) → msn2 | msa reinició dos veces por `kexec-pve` (luego desactivado). Homepage en ImagePullBackOff bloqueó un `prepare`. CSI de worker-02 en CrashLoop ~10 min tras volver msa. Primario de Postgres pasó a `postgres-contactos-1` |
| 2026-09-19 | 7.0.14-11 → 7.0.14-17 | (DELL y msn2 el 18-sep sin el script) → msa (×2) | Primera corrida real del script. msa arrancó el -11; se atribuyó a GRUB, pero era `kexec-pve` |
