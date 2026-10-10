# MikroTik-DDNS-OnlineAlerts

Instalador RouterOS por sitio: **failover recursivo dual-WAN**, LAN, WiFi, hotspot,
WireGuard y un **monitor de WAN** con alertas Telegram/WhatsApp y DDNS automático.

**Desarrollado por [DMZ Sistemas](https://dmz.ar)**

---

## 📦 Archivos

| Archivo | Qué es | ¿Se edita? |
|---------|--------|-----------|
| `dmz-config.example.rsc` | Plantilla de configuración del sitio | Se **copia** a `dmz-config.rsc` |
| `dmz-config.rsc` | Configuración real del sitio (tokens, claves) | **Sí** — es lo único que se edita. Está en `.gitignore` |
| `dmz-engine.rsc` | Motor: valida el config y aplica todo | No |
| `wan-monitor.rsc` | Monitor de WAN (alertas + DDNS). Lo descarga e instala el motor | No |
| `legacy/` | Scripts viejos `ddns-v1..v4` (edición manual de `:local`) | Solo referencia |

---

## 📋 Características

✅ **Una sola configuración por sitio**: todo sale de `dmz-config.rsc`. El motor y el
monitor son iguales para todos los equipos.

✅ **Validación antes de aplicar**: si falta un dato o hay un formato incorrecto, el motor
lista los errores y **no toca nada**.

✅ **Idempotente**: se puede re-correr después de cambiar el config. Todo lo que crea lleva
comentario `dmz:...` y se reemplaza. La clave de WireGuard se conserva.

✅ **WAN1/WAN2** en modo `static`, `dhcp` o `none` (WAN2 es opcional), con routing recursivo.

✅ **Detección de cortes en 2 etapas** (ping al modem, luego ping a la sonda):
- 🔴 Enlace caído (cable/modem/puerto)
- 🟠 Sin internet (ISP/fibra)
- 🟢 Recuperada
- 🔄 IP pública cambió (opcional)

✅ Alerta solo en **cambio de estado** (no repite cada 5 minutos).

✅ **DDNS** vía cdmon, **Telegram** y **WhatsApp** (textmebot).

---

## 🚀 Instalación

### 1. Preparar el config del sitio

En tu PC (no en el repo):

```bash
cp dmz-config.example.rsc dmz-config.rsc
```

Editar `dmz-config.rsc`. Cada bloque está comentado; lo mínimo:

```routeros
:global cfgSiteName        "cliente"
:global cfgIdentity        "MikroTik-Cliente"
:global cfgLanNet          "192.168.88"          ;# 3 octetos: .1 = gateway

:global cfgWan1Mode        "static"              ;# static | dhcp | none
:global cfgWan1Iface       "ether1"
:global cfgWan1Ip          "192.168.17.2/24"
:global cfgWan1Gw          "192.168.17.1"
:global cfgWan1Probe       "1.1.1.1"

:global cfgWan2Mode        "none"                ;# sin failover
```

> Las banderas (`cfgWifi`, `cfgHotspot`, `cfgWireGuard`, `cfgWanMonitor`, ...) van
> **sin comillas**: `true` / `false`. El motor lo valida.

### 2. Subir los archivos al router

Conectarse por un **puerto LAN** (no por el ether de una WAN: el motor lo saca del bridge).

```bash
scp dmz-config.rsc dmz-engine.rsc admin@192.168.88.1:/
```

`wan-monitor.rsc` **no hace falta subirlo**: si `cfgWanMonitor=true`, el motor lo descarga
de `cfgWmUrl` (requiere salida a internet al momento de aplicar).

### 3. Aplicar

```routeros
/import dmz-config.rsc
/import dmz-engine.rsc
```

El primer import solo carga variables. El segundo valida y aplica. Si hay errores se ven así
y no se aplica nada:

```
  ERROR: cfgWifiPassword sigue con el valor de ejemplo
  ERROR: WAN2: gateway invalido
[DMZ-ENGINE] 2 error(es). No se aplico NADA. Corregir dmz-config.rsc y repetir.
```

### 4. WireGuard (si `cfgWireGuard=true`)

El motor genera un par de claves propio del sitio y muestra la public-key:

```routeros
/log print where message~"WIREGUARD"
```

Esa clave se carga como peer en el servidor DMZ. Re-correr el motor **no** cambia la clave.

### 5. Borrar el config del router

`dmz-config.rsc` tiene tokens y contraseñas en texto plano:

```routeros
/file remove dmz-config.rsc
```

---

## 🛰️ WAN monitor

El monitor (`wan-monitor.rsc`) **no tiene zona de configuración**. En cada corrida ejecuta
el script `dmz-vars`, que el motor genera con los `:global` del sitio, y lee de ahí sus
valores. Como `dmz-vars` es un script del router, sobrevive reinicios.

Lo que instala el motor:

| Objeto | Contenido |
|--------|-----------|
| `/system script dmz-vars` | `:global cfgWm*`, `cfgWan1*`, `cfgWan2*` del sitio. En modo `dhcp` el gateway se lee del dhcp-client en cada corrida |
| `/system script wan-monitor` | Contenido descargado de `cfgWmUrl` |
| `/system scheduler wan-monitor` | Corre el monitor cada `cfgWmInterval` |

**No editar `dmz-vars` a mano**: cambiar `dmz-config.rsc` y volver a correr el motor.

Para usar el monitor suelto (sin el motor), crear a mano un script `dmz-vars` con estos
`:global` y las rutas recursivas de la sección siguiente:

```routeros
:global cfgWan1Gw "192.168.17.1";  :global cfgWan1Probe "1.1.1.1"
:global cfgWan2Mode "none";        :global cfgWan2Gw "";  :global cfgWan2Probe ""
:global cfgWmDebug false;          :global cfgWmNotifyIpChange false
:global cfgWmTelegram true;        :global cfgWmTgToken "TU_BOT_TOKEN";  :global cfgWmTgChatId "TU_CHAT_ID"
:global cfgWmWhatsapp false;       :global cfgWmWaPhone "";  :global cfgWmWaApiKey ""
:global cfgWmDdns false;           :global cfgWmDdnsDomain "";  :global cfgWmDdnsUser "";  :global cfgWmDdnsHash ""
```

### Variables del monitor

| Variable | Descripción |
|----------|-------------|
| `cfgWanMonitor` | Instalar el monitor (`true`/`false`) |
| `cfgWmUrl` | URL raw de `wan-monitor.rsc` |
| `cfgWmInterval` | Cada cuánto corre (ej: `5m`) |
| `cfgWmDebug` | Log detallado de cada corrida |
| `cfgWmTelegram` / `cfgWmTgToken` / `cfgWmTgChatId` | Alertas por Telegram |
| `cfgWmWhatsapp` / `cfgWmWaPhone` / `cfgWmWaApiKey` | Alertas por WhatsApp (textmebot) |
| `cfgWmDdns` / `cfgWmDdnsDomain` / `cfgWmDdnsUser` / `cfgWmDdnsHash` | DDNS cdmon (solo con WAN1 UP) |
| `cfgWmNotifyIpChange` | Avisar cuando cambia la IP pública |

### Configurar Telegram

1. En Telegram, abrir `@BotFather` → `/newbot` → copiar el **token**.
2. Abrir el chat con el bot y escribir `/start`.
3. Visitar `https://api.telegram.org/bot<TOKEN>/getUpdates` y copiar el `"id"` del chat.

### Configurar DDNS (cdmon)

1. En el panel de cdmon, crear el dominio dinámico.
2. Copiar el **usuario** y el **hash MD5** de la configuración del dominio.

```
# IP registrada:
https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=usuario&p=hash
# Actualizar:
https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=usuario&p=hash&cip=NUEVA_IP
```

---

## 📖 Documentación técnica

### Routing recursivo

El motor crea, por cada WAN activa:

```routeros
/ip route add dst-address=<sonda>/32 gateway=<gw>%<iface> scope=10
/ip route add dst-address=0.0.0.0/0 gateway=<sonda> target-scope=11 distance=<1|2> check-gateway=ping
```

- La sonda queda **clavada** a su WAN: el ping a `cfgWan1Probe` siempre sale por WAN1.
- Si la sonda deja de responder, la ruta por defecto de esa WAN queda Inactive y el
  tráfico pasa a la otra (distance 1 → 2).
- `target-scope=11` es crítico: con 10 la ruta queda **Inactive**.
- En modo `dhcp`, el dhcp-client tiene un script que actualiza el gateway de la ruta a la
  sonda cada vez que renueva el lease.
- Las rutas por defecto estáticas que no creó el motor se eliminan (romperían el failover).

> La sonda no puede ser la misma IP que `cfgLanDnsUpstream`: todo el DNS quedaría atado a
> una sola WAN. El motor lo valida.

### Detección en 2 etapas

| Etapa | Prueba | Si falla |
|-------|--------|----------|
| 1 | Ping al gateway/modem de la WAN | 🔴 `LINK_DOWN` |
| 2 | Ping a la sonda de la WAN | 🟠 `NO_INET` |

El estado se guarda en `:global wan1LastStatus` / `wan2LastStatus` y solo se alerta cuando
cambia.

### Qué hace el motor (en orden)

1. **Valida** todas las variables. Con errores, aborta sin cambios.
2. **Identidad**: nombre, zona horaria, NTP, contraseña de `admin` (si no está vacía).
3. **Bridge y listas**: crea `WAN`/`LAN` si faltan; todos los ethernet que no son WAN van al bridge.
4. **LAN**: `.1/24` en el bridge, pool `.10-.254`, DHCP, DNS con `cfgLanDnsUpstream`,
   leases fijos y DNS estático.
5. **WAN1/WAN2**: IP o dhcp-client, lista `WAN`, rutas recursivas.
6. **NAT y firewall**: masquerade hacia `WAN`. Si el equipo tiene el firewall de fábrica
   (`defconf`) se respeta; si no tiene ninguno, se crea uno equivalente. Port forwarding.
7. **WiFi** (paquete `wireless`): SSID 2.4/5 GHz con WPA2.
8. **Hotspot**: VLAN `cfgHsVlanId` sobre el bridge (`vlan-filtering=yes`), puerto cableado
   `cfgHsIface` y AP virtual `wlan-hs`, aislado de la LAN y sin acceso a la gestión del router.
9. **WireGuard**: interfaz `wg-dmz`, peer del servidor y rutas a `cfgWgRemoteNets`.
10. **WAN monitor**: `dmz-vars`, descarga de `wan-monitor`, scheduler.

### Formatos de listas

| Variable | Formato | Ejemplo |
|----------|---------|---------|
| `cfgPortForward` | `puerto:ip:puertoDestino:protocolo,...` | `80:192.168.88.200:80:tcp` |
| `cfgStaticLeases` | `mac\|ip\|comentario,...` | `78:2B:CB:00:00:01\|192.168.88.200\|Servidor` |
| `cfgStaticDns` | `nombre\|ip,...` | `nas.lan\|192.168.88.200` |
| `cfgHsWalledGarden` | `host,...` | `*.mercadopago.com` |

`""` = ninguno. Los comentarios de leases no pueden llevar comas.

---

## 🔧 Troubleshooting

### "No hay variables cargadas"

Falta `/import dmz-config.rsc` antes del motor (las variables se pierden al reiniciar).

### "No se pudo descargar wan-monitor.rsc"

El router no tenía internet al aplicar, o `cfgWmUrl` es incorrecta. Probar:

```routeros
/tool fetch url="https://raw.githubusercontent.com/briantierno/Mikrotik-DDNS-OnlineAlerts/main/wan-monitor.rsc" output=user
```

Corregir y volver a correr los dos imports.

### "[WAN-MONITOR] No se encontro el script dmz-vars"

El monitor se instaló a mano sin el motor. Ver "usar el monitor suelto" más arriba.

### "La alerta no llega a Telegram"

```routeros
/tool fetch url="https://api.telegram.org/bot<TOKEN>/getMe" output=user
```

Debe devolver un JSON con los datos del bot. Para ver cada corrida: `cfgWmDebug true`.

### "La ruta recursiva queda Inactive"

Verificar `target-scope=11` en la ruta por defecto y `scope=10` en la ruta a la sonda.

### "Detecta caídas falsas"

El modem no responde ping, o la sonda bloquea ICMP. Cambiar `cfgWan1Probe`/`cfgWan2Probe`
(ej: `1.1.1.1`, `8.8.4.4`, `9.9.9.9`) y re-correr el motor.

---

## 🔐 Seguridad

⚠️ **Este repo es PÚBLICO.** `dmz-config.rsc` está en `.gitignore`; solo se sube
`dmz-config.example.rsc` con valores de ejemplo. Nunca commitear:

- Tokens de Telegram ni Chat IDs
- Hashes de cdmon ni API keys
- Teléfonos
- Claves de WiFi, de `admin` ni de WireGuard
- Nombres, dominios o IPs públicas de clientes

En el router, los tokens quedan dentro del script `dmz-vars`: proteger el acceso a la
gestión del equipo y borrar `dmz-config.rsc` después de aplicar.

---

## 📚 Referencias

- [MikroTik RouterOS Scripting](https://help.mikrotik.com/docs/display/ROS/Scripting)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [cdmon](https://www.cdmon.com)
- [ipinfo.io](https://ipinfo.io)

---

## 👨‍💻 Soporte & Contacto

Desarrollado por **DMZ Sistemas**

- 🌐 [dmz.ar](https://dmz.ar)
- 📱 [WhatsApp: +54 11 7828-5893](https://wa.me/541178285893)

---

## 📄 Licencia

MIT — ver [LICENSE](LICENSE).

---

**Versión de RouterOS objetivo**: 7.x (familia `wireless`: hAP ac, cAP ac)
**Scripts anteriores**: ver [`legacy/`](legacy/)
