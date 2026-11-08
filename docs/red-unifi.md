# Red doméstica UniFi — configuración y runbook

Última revisión: **2026-11-08** (auditoría y correcciones del 2026-11-07, hechas con Claude).
Skill asociada: `~/.claude/skills/red-unifi/`, con el script `unifi.sh` que ejecuta los
procedimientos de §6.

> Este documento es una foto del estado al 2026-11-08. Antes de actuar sobre un dato puntual
> (canal, IP, cliente), confírmalo en vivo con `unifi.sh status` o `unifi.sh radios`.

---

## 0. Reglas de la casa

1. **Los APs sin cable (mesh) no llevan IP fija ni canal fijo.** Hoy son el **COMEDOR** y el
   **Express (UX)**: IP por DHCP y canales en automático. Sí tienen una lista de **AP padre
   preferido**, que Ricardo define desde el web client.
2. **Al Express solo se le hacen cambios desde el web client.** Nunca por MongoDB ni forzando
   su `cfgversion`: el 2026-11-07 quedó aislado tres veces así (§5b).
3. **Cualquier IP estática nueva** (VM, servidor) se registra como reserva DHCP en el UDM (§4).
4. **Ningún AP en canales DFS (52–144)**, y 2.4 GHz siempre a 20 MHz.
5. **Cambios de configuración agrupados en un solo reinicio** de la app Network. Avisar a
   Ricardo antes: durante 1–2 minutos el web client muestra los APs desconectados.
6. **Ricardo usa el web client**, no la app móvil.

## 1. Topología

```
INTERNET (ISP ~1G)
   │ eth8 (WAN RJ45)
┌──┴──────────────────────────┐
│ UDM Pro "RWAGNER" .254      │  UniFi OS 5.1.35 · gateway, DHCP, controlador Network
└──┬──────────────────────┬───┘
   │ eth9 SFP+ (DAC 1m)   │ eth10 SFP+ 10G
   │                      │
┌──┴───────────────┐   ┌──┴──────────────────────────────┐
│ USW-Aggregation  │   │ USW-Pro-24-PoE .228  (rack)     │
│ .240  (p7←UDM)   │   │  p2  → U6-Pro .187  (PoE)       │
│  p4 → fibra 10G  │   │  p3  → PATIO .146   (PoE)       │
└──┬───────────────┘   │  p14 → ENTRADA .252 (PoE)       │
   │                   │  p11 ↔ USW-24-PoE .219 (p19)    │
   │                   │  p26 → UDM (10G)                │
┌──┴──────────────────────────┐ └─────────────────────────┘
│ MikroTik CRS309 .73 (oficina)│
│  bridge plano bridgeLAN      │──► Mac mini .201 (10G), Hermes .92 (10G),
│  (detalle: memoria           │    MacBook .8 (2.5G), TrueNAS .100 (10G),
│   revision-red-servidores)   │    clúster K3s / Proxmox, AP DORMITORIO .229
└──────────────────────────────┘

Inalámbrico (mesh, sin cable posible):
  U6-Pro .187 ──5 GHz──► COMEDOR-IW-HD (DHCP) ──PoE──► USW-Lite-8-PoE .106 ──► TV Sony .128 (100M)
  ENTRADA .252 ──5 GHz──► Express / UX (DHCP)  ──puerto──► Nvidia 00:04:4b:bc:ab:59
```

- Red única plana `192.168.1.0/24`, todavía sin VLANs. El diseño de VLANs está pendiente; ver la
  memoria `revision-red-servidores`.

## 2. Equipos UniFi

| Nombre | Modelo | IP | MAC | Firmware | Uplink |
|---|---|---|---|---|---|
| RWAGNER (UDM Pro) | UDMPRO | .254 | 68:d7:9a:31:1e:55 | 5.1.35 | WAN ISP |
| USW Aggregation | USL8A | .240 fija | 78:45:58:6f:59:ec | 7.5.15 | UDM eth9 |
| USW-Pro-24-PoE | US24PRO | .228 fija | 68:d7:9a:4b:ff:66 | 7.5.15 | UDM eth10 |
| USW-24-PoE | USL24PB | .219 fija | e4:38:83:98:46:6a | 7.5.15 | USW-Pro p11 |
| USW-Lite-8-PoE | USL8LPB | .106 fija | ac:8b:a9:b1:30:96 | 7.5.15 | COMEDOR (PoE + datos) |
| U6-Pro | UAP6MP | .187 fija | 60:22:32:a7:86:c5 | 6.8.2 | USW-Pro p2 |
| ENTRADA | UAP-AC-Mesh | .252 fija | b4:fb:e4:70:8e:77 | 6.8.2 | USW-Pro p14 |
| PATIO | UAP-AC-Mesh | .146 fija | b4:fb:e4:70:91:af | 6.8.2 | USW-Pro p3 |
| DORMITORIO | UAP In-Wall HD | .229 fija | 74:ac:b9:d3:25:bd | 6.7.57 | Aggregation p4 (lado oficina) |
| COMEDOR-IW-HD | UAP In-Wall HD | **DHCP** (.218) | 60:22:32:fc:37:d9 | 6.7.57 | **mesh**, padres: U6-Pro → ENTRADA |
| Express (UX) | UniFi Express | **DHCP** (.180) | 94:2a:6f:0c:38:ca | 4.0.25 | **mesh**, padres: ENTRADA → PATIO |

Notas:
- **ENTRADA y PATIO** son dos UAP-AC-Mesh distintos. Hasta el 2026-11-07 ambos se llamaban
  "ENTRADA"; el del patio se identificó haciéndole parpadear el LED (§6.5).
- El **COMEDOR** no admite cable. Funciona como puente: recibe red por mesh y alimenta por PoE
  al USW-Lite-8, donde está cableada la TV del comedor (Sony `14:3f:a6:8f:91:20`, .128, puerto
  3, 100 Mbps; ese es el límite de la tarjeta de la TV).
- El **Express** fue reseteado de fábrica y readoptado el 2026-11-07 a las 20:08. **No acepta
  la llave SSH**, así que se verifica desde el controlador o desde su AP padre.
- UniFi guarda **solo dos padres preferidos** por AP mesh (`mesh_uplink_1` y `_2`).
- Los LEDs de los APs están **apagados por configuración**.

## 3. WiFi

### SSIDs
| SSID | Bandas | Uso |
|---|---|---|
| `dd-wrt1` | 2.4 + 5 GHz | red principal |
| `sensibo` | 2.4 GHz | IoT (Sensibo y otros) |
| `vwire-…` (oculto) | 5 GHz | enlace mesh entre APs; no tocar |
| `element-…` (oculto) | 2.4 + 5 GHz | interno de UniFi; no tocar |

### Canales (2026-11-08)

| AP | 2.4 GHz | 5 GHz | Potencia |
|---|---|---|---|
| U6-Pro | 6 / 20 MHz | **157 / 40 MHz** (padre mesh del COMEDOR) | 5 GHz alta |
| ENTRADA | 6 / 20 MHz | 36 / 40 MHz (padre mesh del Express) | auto |
| PATIO | 6 / 20 MHz | 149 / 40 MHz | auto (switches de riego en 2.4) |
| DORMITORIO | 1 / 20 MHz | 44 / 40 MHz | auto |
| COMEDOR-IW-HD | **auto** (hoy 11) | auto (sigue al padre) | auto |
| Express | **auto** | **auto** (sigue al padre) | auto |

Criterios:
- **Ningún AP en canales DFS (52–144).** Si el AP detecta un radar está obligado a cambiar de
  canal, y eso corta el mesh. Pasó el 2026-11-07 a las 11:36 con el ENTRADA en el canal 100.
- **2.4 GHz siempre a 20 MHz** y solo en los canales 1, 6 y 11. Cerca del DORMITORIO hay más de
  140 redes vecinas en 2.4 GHz y el canal está ocupado ~50 % del tiempo.
- **Mesh del COMEDOR al U6-Pro** (decisión de Ricardo): −52/−56 dBm, 4 flujos, 800 Mbps. Por el
  ENTRADA eran −61/−73 dBm, 2 flujos y 400 Mbps.
- **ESP_4FF9E4** (`84:0d:8e:4f:f9:e4`, IP por DHCP, módulo Espressif de domótica): el 2026-11-07 se
  quedaba buscando el canal 11 y se colgó del DORMITORIO a −86 dBm. El 2026-11-08 está en el
  U6-Pro, canal 6, −61 dBm. Si vuelve a aparecer con señal débil, se corrige del lado del ESP
  (reiniciarlo). No se fija el canal del COMEDOR (regla 1).

## 4. DHCP e IPs

- Servidor DHCP: **solo el UDM**. Rango `192.168.1.101–.253`, lease de 24 h, router `.254`,
  DNS `1.1.1.1`. dnsmasq hace ping antes de entregar una IP nueva.
- **IP fija configurada en el propio equipo:** todos los switches y los APs cableados (§2).
  Los APs mesh van por DHCP (regla 1).
- **Reservas DHCP** (≈71, colección `ace.user`): masters y workers K3s `.21–.27`, MikroTik
  `.73`, TrueNAS `.100`, Alexa `.102`. Agregadas el 2026-11-07: msa `.143`, Mac mini `.201`,
  Dockershim `.205`, PBS `.230`, VM-N8N `.234`.
- **Regla 3:** cualquier IP estática nueva debe registrarse como reserva en el UDM. Si no, tarde
  o temprano un cliente DHCP se la roba (incidentes del 2026-08-14 y del 2026-11-07).

## 5. Incidente 2026-11-07 — DHCP intruso

**Síntoma:** los clientes WiFi recibían gateway `192.168.1.100` y no navegaban.

**Causa:** Incus (el motor de VMs de TrueNAS 25.10) estaba inicializado con
`v4_network = 192.168.1.100/24`, la subred de la LAN. Su dnsmasq (`incusbr0`,
`--dhcp-authoritative`, pool .2–.254, `domain_name=incus`) respondía DHCP en la LAN desde el
2026-11-02. Le dio IP a 21 equipos, y dos chocaron con infraestructura: la Alexa tomó la `.26`
(k3s-worker-03) y el S23 la `.73` (MikroTik).

**Corrección:** `midclt call -j virt.global.update '{"v4_network": "10.250.0.1/24"}'` en
TrueNAS.

**Cómo detectarlo:** en un cliente afectado, `ipconfig getpacket en1` muestra un
`server_identifier` distinto de `.254` (y `domain_name = incus`). `unifi.sh dhcp-check` escucha
75 s en el UDM y lista todos los servidores DHCP y RA que responden.

## 5b. Incidente 2026-11-07 — Express (UX) aislado (19:30–20:43)

**Qué se hizo:** desde MongoDB se le puso IP fija y AP padre preferido = U6-Pro, y se forzó la
configuración (cambio de `cfgversion` + reinicio de la app Network).

**Qué pasó:**
- El UX quedó asociado a su padre por radio, pero **sin tráfico**: el padre le transmitía 0
  paquetes y el controlador lo marcaba "isolated".
- Ocurrió **tres veces**, siempre justo después de un empuje forzado de configuración: a las
  19:29 (IP fija + padre), a las 19:47 (al revertir) y a las 20:13 (lista de padres).
- Un apagado y encendido solo lo recuperó unos 30 segundos, hasta que recibió la siguiente
  configuración.
- Con la **adopción normal**, en cambio, funcionó perfecto, incluso colgado del U6-Pro
  (−54 dBm). La supuesta incompatibilidad UX ↔ U6-Pro era falsa: el problema era el método.

**Cómo se recuperó:**
1. Se olvidó el equipo en el controlador.
2. Ricardo lo reseteó de fábrica.
3. Ricardo lo readoptó desde el web client.
4. Ricardo definió los padres desde el web client: ENTRADA y luego PATIO.

Desde las 20:43 está estable: el 2026-11-08 llevaba 14,6 h sin cortes y 0 % de pérdida.

**Lecciones:**
- El Express es un equipo "UDAPI": se configura distinto a los otros APs. **No se toca por
  MongoDB** (regla 2).
- Un equipo mesh aislado no recibe configuración nueva. Si se traba, solo se recupera con
  intervención física (apagar y prender, o reset de fábrica).
- Para readoptar: primero **olvidarlo** en el controlador, después resetearlo de fábrica y
  después adoptarlo. Un AP mesh reseteado no aparece solo como "pendiente": se presenta por
  Bluetooth desde la app móvil o con un cable temporal a cualquier switch.

## 6. Procedimientos

Todo se hace por SSH con la llave ed25519 de la Mac mini:
- **UDM:** `ssh root@192.168.1.254`.
- **APs y switches:** `ssh rwagner@<ip>`. La llave está cargada en *Settings → Device SSH
  Authentication*. El **Express no acepta la llave**.
- **Sin contraseñas:** quedan fuera tanto la API web del UDM como el SSH por contraseña.

### 6.1 Ver estado en vivo
`mca-dump` en cada AP o switch devuelve un JSON con:
- radios y VAPs;
- clientes, con señal y tasa;
- uso de canal (`radio_table[].athstats.cu_total`);
- redes vecinas (`scan_table`);
- puertos y LLDP.

`unifi.sh status`, `radios`, `clients` y `ports` lo resumen.

### 6.2 Cambiar la configuración de un equipo sin la UI (solo equipos cableados)
La configuración vive en MongoDB del UDM (`mongo --port 27117 ace`, colección `device`).
**Nunca aplicar esto al Express**, ni fijar IP o canal a APs mesh (reglas 1 y 2).

1. **Respaldar** el documento en `/root/backups/` del UDM.
2. Editar el campo (`radio_table.$.channel`, `ht`, `tx_power_mode`, `config_network`, `name`,
   `mesh_uplink_1/2`…). **Los números van con `NumberInt()`**: el shell de mongo guarda
   decimales y el controlador falla en cada inform con `NumberFormatException: "36.0"`.
3. Cambiar el `cfgversion` del equipo a otro hex de 16 caracteres. Sin esto el controlador no
   detecta el cambio.
4. `systemctl restart unifi.service` (~30 s). Agrupar todos los cambios en un solo reinicio
   (regla 5).
5. Verificar con `mca-dump` que el equipo tomó la configuración.

`unifi.sh set-radio`, `set-static` y `apply` hacen los pasos 1–4 y rechazan los APs mesh y el
Express.

Notas:
- El grupo de WLAN "Off" (`wlangroup_id_ng`) **no** apaga una radio en esta versión: los SSID
  usan `ap_group_mode=all`. Para "apagar" el 2.4 GHz de un AP se usa `tx_power_mode: "low"`.
- El cambio de AP padre (`mesh_uplink_1`) solo se aplica cuando el AP hijo se reinicia.
- Para verificar si un AP usa DHCP, por SSH usar `ps w | grep -c "[u]dhcpc"`. No usar
  `pgrep -f udhcpc`, porque se detecta a sí mismo.

### 6.3 Reservas DHCP
`unifi.sh reserve <MAC> <IP> <nombre>` pone `use_fixedip: true`, `fixed_ip` y
`network_id: 633bd8cf1de8d40762efe1fc` en `ace.user`.

En UniFi OS 5.1.35 **reiniciar servicios no regenera** el archivo de dnsmasq. Hay que
**reprovisionar el gateway**:
1. `unifi.sh apply 68:d7:9a:31:1e:55` (cambia el `cfgversion` del UDMPRO y reinicia
   `unifi.service`).
2. En ~1 min se regenera
   `/run/dnsmasq.dhcp.conf.d/dhcp.dhcpServers-net_LAN1_br0_192-168-1-0-24.conf`.
3. dnsmasq se reinicia, con un corte de DNS de pocos segundos.

### 6.4 Expulsar un cliente WiFi
En el AP donde está: `hostapd_cli -p /var/run/hostapd -i <iface> deauthenticate <MAC>`.
`unifi.sh kick <MAC>` lo busca en todos los APs.

Los Android suelen reconectarse **conservando su IP** sin pedir DHCP. Para forzar una IP nueva
hay que esperar que venza el lease, u "olvidar la red" en el teléfono.

### 6.5 Ubicar físicamente un AP (LED)
Los LEDs están apagados por configuración y `/proc/gpio/led_pattern` no se ve.
- **Para que parpadee:** usar `/sys/class/leds/ubnt:{blue,white}:dome` con `trigger=timer` y
  `brightness=255`.
- **Para restaurar:** `trigger` en external1 (azul) y external0 (blanco), y `brightness=0`.

`unifi.sh locate <ip> [segundos]` hace las dos cosas.

## 7. Pendientes

- [ ] Averiguar por qué el Express no acepta la llave SSH.
- [ ] Equipo con chip TI `94:e3:6d:a0:2d:c4` (nombre en el UDM: "Ricardos-iPad-2"): no volvió
      tras el incidente. Desenchufarlo y volverlo a enchufar.
- [ ] Cable DAC USW-Aggregation p7 ↔ UDM: 3,6 M de errores de recepción históricos, 0 nuevos al
      2026-11-07. Vigilar; si crece, cambiar el DAC.
- [ ] USW-24-PoE, puertos 3, 10 y 23 a 100 Mbps: revisar los cables si los equipos son gigabit.
- [ ] Diseño de VLANs (Gestión / Clúster / Storage / Clientes / IoT / Invitados); ver la
      memoria `revision-red-servidores`.
- [ ] Revisar periódicamente que no haya otro servidor DHCP: `unifi.sh dhcp-check`.
