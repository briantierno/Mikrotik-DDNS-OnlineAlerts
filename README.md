# Mikrotik-DDNS-OnlineAlerts

Scripts para **MikroTik RouterOS** que monitorean enlaces dual-WAN, detectan cortes reales de fibra/ISP mediante **failover recursivo**, actualizan registros **DDNS en cdmon.org** y envían **alertas por Telegram y WhatsApp**.

Desarrollado por **DMZ Sistemas** — [dmz.ar](https://dmz.ar) · [WhatsApp](https://wa.me/541178285893)

---

## ✨ Características

- **Detección en 2 etapas:** enlace local (modem) + internet real (ping a host remoto).
- **Failover recursivo:** detecta caídas de fibra/ISP aunque el modem siga vivo (algo que `check-gateway=ping` solo no logra).
- **DDNS inteligente:** consulta la IP registrada en cdmon y actualiza únicamente si cambió.
- **Alertas en tiempo real:** Telegram y WhatsApp (mensajes URL-encoded con emojis).
- **Log limpio en producción:** flag `debugEnabled` para silenciar la salida.
- **Liviano:** corre en hardware MIPS mono-core (probado en RB2011UiAS-2HnD, ROS 7.20.7).

---

## 📦 Versiones

| Versión | WAN1 | WAN2 | Caso de uso |
|---------|------|------|-------------|
| [**V1**](scripts/v1-wan2-pppoe.rsc) | Estática | PPPoE (`ppp-out1`) | WAN2 es ADSL/PPPoE con usuario y contraseña |
| [**V2**](scripts/v2-dual-wan-estatica.rsc) | Estática | Estática (IP fija) | Dos modems en bridge con IP local fija |
| [**V3**](scripts/v3-wan2-dhcp-starlink.rsc) | Estática | DHCP dinámico | Starlink, modem DHCP o IP dinámica del proveedor |

> En todas las versiones la **WAN1 es IP estática**. Lo que cambia es la topología de la WAN2.

---

## 🚀 Inicio rápido

1. Elegí la versión según tu WAN2 (ver tabla).
2. Abrí el `.rsc` y completá la **ZONA DE CONFIGURACIÓN** (credenciales, dominios, interfaces).
3. Configurá el **routing recursivo** de WAN1 (comandos comentados dentro del script).
4. Cargá el script en **System → Scripts** y programalo en **System → Scheduler** (ej: cada `5m`).

```
/system script run ddns-check
/log print where topics~script
```

La documentación completa (comparativa, routing, troubleshooting y aprendizajes técnicos) está en **[docs/documentacion-completa.html](docs/documentacion-completa.html)**.

---

## ⚙️ Configuración

Cada script tiene una zona de configuración al inicio. Reemplazá los placeholders por tus valores:

```rsc
:local debugEnabled false                 ;# true = ves todo | false = producción

# Telegram
:local telegramEnabled true
:local telegramToken "TU_BOT_TOKEN_AQUI"
:local telegramChatId "TU_CHAT_ID_AQUI"

# DDNS (cdmon)
:local ddns1Domain "tudominio.com"
:local ddns1User "TU_USUARIO_DDNS"
:local ddns1Hash "TU_HASH_MD5_AQUI"       ;# md5 de tu password cdmon
```

> ⚠️ **Nunca subas tus credenciales reales a un repo público.** Los scripts de este repo usan placeholders a propósito.

---

## 🛰️ Nota sobre CGNAT (Starlink residencial)

Starlink residencial usa **CGNAT** (rango `100.64.0.0/10`): no entrega IP pública configurable, por lo que el DDNS no aplica. En la V3 el flag `wan2DdnsEnabled` viene en `false` y la WAN2 queda solo en modo monitoreo. Activalo (`true`) únicamente si tu proveedor te da IP pública directa.

---

## 🧠 Notas técnicas clave

- `target-scope=11` es necesario en ROS 7.20.7 para que la ruta default recursiva quede activa.
- `/tool fetch` **no** acepta `interface=` ni `routing-table=` — solo `src-address=`.
- `/ping` sí acepta `interface=`, `src-address=` y `routing-table=`.
- En RouterOS `:find` devuelve `""` (no `-1`) cuando no encuentra una subcadena.

---

## 📄 Licencia

MIT — ver [LICENSE](LICENSE).

---

<p align="center">
  <strong>DMZ Sistemas</strong> — Brian Tierno<br>
  <a href="https://dmz.ar">dmz.ar</a> · <a href="https://wa.me/541178285893">WhatsApp</a>
</p>
