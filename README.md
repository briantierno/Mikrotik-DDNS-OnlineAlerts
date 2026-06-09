# MikroTik-DDNS-OnlineAlerts

Scripts RouterOS para **failover recursivo dual-WAN**, actualización DDNS automática y alertas Telegram/WhatsApp.

**Desarrollado por [DMZ Sistemas](https://dmz.ar)**

---

## 📋 Características

✅ **3 variantes** según tu configuración de WAN:
- **V1**: WAN1 estática (PPPoE) + WAN2 dinámico  
- **V2**: WAN1 y WAN2 ambas estáticas  
- **V3**: WAN1 estática + WAN2 DHCP (Starlink/ISP dinámico)

✅ **Detección de cortes en 2 etapas**:
1. Chequeo de enlace (cable/modem)
2. Chequeo de conectividad real (ping a internet)

✅ **Routing recursivo** para detectar caídas de fibra sin falsas alarmas

✅ **DDNS automático** via cdmon.org (soporta otros proveedores)

✅ **Alertas múltiples**:
- 🔴 Enlace caído
- 🟠 Sin internet  
- 💚 IP pública cambió

✅ **Canales de notificación**:
- Telegram
- WhatsApp (textmebot)

---

## 🚀 Instalación Rápida

### 1. Conectar por SSH al router

```bash
ssh admin@TU_IP_ROUTER
```

### 2. Seleccionar la versión según tu equipo

| Versión | WAN1 | WAN2 | Usar si... |
|---------|------|------|-----------|
| **V1** | PPPoE | Dinámico | Tienes configuración PPPoE en WAN2 |
| **V2** | Estática | Estática | Ambos WANs tienen IP estática asignada |
| **V3** | Estática | DHCP | WAN2 es Starlink o ISP con DHCP dinámico |

### 3. Copiar y adaptar el script

```routeros
# 1. En MikroTik, ir a System > Scripts > Add New
# 2. Copiar el contenido completo del script (V1, V2 o V3)
# 3. Ir a la sección "ZONA DE CONFIGURACIÓN" y editar:

:local wan1Interface "ether1::ISP1"          # Cambiar por tu interface
:local wan2Interface "ether2::ISP2"          # Cambiar por tu interface
:local wan1Gateway "192.168.10.1"            # IP del gateway/modem
:local wan2Gateway "192.168.20.1"            # IP del gateway/modem

:local telegramToken "YOUR_TELEGRAM_BOT_TOKEN"
:local telegramChatId "YOUR_TELEGRAM_CHAT_ID"
:local ddns1User "your_cdmon_username"
:local ddns1Hash "YOUR_CDMON_HASH_MD5"
```

### 4. Configurar Telegram (requerido)

**Crear un bot de Telegram:**
1. Abre Telegram, busca `@BotFather`
2. Escribe `/newbot` y sigue las instrucciones
3. Copia el **token** (ej: `123456789:ABCdefGHIjklMNOpqRSTuvwxyz`)
4. Obtén tu **Chat ID**:
   - Abre el chat con tu bot
   - Escribe `/start`
   - Visita `https://api.telegram.org/botTU_TOKEN/getUpdates`
   - Busca `"id": XXXXXXX` — ese es tu Chat ID

### 5. Configurar DDNS (cdmon)

1. Ir a https://www.cdmon.com → Panel de Control
2. Crear un dominio dinámico (ej: `tudominio.com`)
3. Obtener las credenciales:
   - **Usuario**: tu usuario de cdmon
   - **Hash MD5**: generado por cdmon (en configuración del dominio)

### 6. Crear tabla de routing para WAN2 (solo V2 y V3)

```routeros
# En MikroTik Terminal:
/routing table add name=salida_WAN2 fib
/ip route add dst-address=0.0.0.0/0 gateway=192.168.20.1 routing-table=salida_WAN2
/routing rule add src-address=192.168.20.254 action=lookup table=salida_WAN2
```

### 7. Configurar routing recursivo para WAN1

```routeros
# En MikroTik Terminal (ejecutar UNA VEZ):
/ip route add dst-address=1.1.1.1/32 gateway=192.168.10.1 scope=10
/ip route add dst-address=0.0.0.0/0 gateway=1.1.1.1 target-scope=11 distance=1 check-gateway=ping
```

**Importante**: `target-scope=11` es crítico en RouterOS 7.20.7 para que la ruta recursiva quede **Active**.

### 8. Agendar el script para ejecutarse periódicamente

```routeros
# En MikroTik, ir a System > Scheduler > Add New

name: DDNS-Sync
on-event: /system script run ddns-script-v3    # (cambiar v3 por tu versión)
interval: 5m                                    # Ejecutar cada 5 minutos
```

---

## 📖 Documentación Técnica

### Lógica de Detección (2 Etapas)

**Etapa 1: ¿Está el enlace activo?**
- V1/V2: Ping al gateway local
- V3: Verificar si la interface DHCP tiene IP asignada

**Etapa 2: ¿Hay internet real?**
- Ping a servidor de internet (8.8.8.8 o similar)

Si ambas pasan → **WAN UP** ✅  
Si falla Etapa 1 → **🔴 ENLACE CAÍDO** (cable/modem/puerto)  
Si falla Etapa 2 → **🟠 SIN INTERNET** (ISP/fibra caída)

### Lógica DDNS

1. Obtiene la IP registrada en cdmon via API
2. Obtiene la IP pública actual via `ipinfo.io`
3. Si difieren → actualiza en cdmon
4. Envía alerta si cambió (opcional, `notifyIpChange`)

```routeros
# URL cdmon para obtener IP registrada:
https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=usuario&p=hash

# URL para actualizar IP:
https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=usuario&p=hash&cip=NUEVA_IP
```

### Routing Recursivo

El routing recursivo permite que RouterOS detecte si el ISP/fibra cae, no solo si el modem pierde cable.

**Sin recursivo**: Ping a 8.8.8.8 via modem (modem responde aunque fibra esté caída)  
**Con recursivo**: Ping a 8.8.8.8 → resuelve via ruta a 1.1.1.1 → si 1.1.1.1 no se alcanza, falla la ruta default

```
# Ruta recursiva:
Target: 0.0.0.0/0
Gateway: 1.1.1.1 (que a su vez va via 192.168.10.1)
target-scope: 11
check-gateway: ping
```

Esto crea una cadena: `WAN1 IP` → ping a `1.1.1.1` (Cloudflare) → si no contesta, la ruta default queda Inactive.

### Tabla de Routing para WAN2 (solo V2/V3)

En V2 y V3, para que `/tool fetch` egrese por WAN2, necesitamos una tabla de routing dedicada:

```routeros
# Tabla:
/routing table add name=salida_WAN2 fib

# Ruta en tabla:
/ip route add dst-address=0.0.0.0/0 gateway=192.168.20.1 routing-table=salida_WAN2

# Regla: si el paquete sale desde 192.168.20.254, usa tabla salida_WAN2
/routing rule add src-address=192.168.20.254 action=lookup table=salida_WAN2
```

Luego en el script, el ping usa `src-address=192.168.20.254` para forzar egreso por WAN2.

### Variables Clave

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `wan1Interface` | Interface física de WAN1 | `ether1::ISP1` |
| `wan2Interface` | Interface física de WAN2 | `ether2::ISP2` |
| `wan1Gateway` | IP del gateway/modem WAN1 | `192.168.10.1` |
| `wan2Gateway` | IP del gateway/modem WAN2 | `192.168.20.1` |
| `ddns1Domain` | Dominio dinámico WAN1 | `ejemplo.com` |
| `ddns1User` | Usuario cdmon | `your_cdmon_username` |
| `ddns1Hash` | Hash MD5 de credencial | `YOUR_CDMON_HASH_MD5` |
| `telegramToken` | Token del bot de Telegram | `YOUR_TELEGRAM_BOT_TOKEN` |
| `telegramChatId` | Chat ID destino de alertas | `YOUR_TELEGRAM_CHAT_ID` |
| `debugEnabled` | Verbosidad de logs | `false` (producción) |

---

## 🔧 Troubleshooting

### "Alerta no llega a Telegram"

**Verificar:**
1. Token y Chat ID están correctos
2. `telegramEnabled = true`
3. Router tiene internet (WAN1 o WAN2 activa)
4. En RouterOS Terminal, probar:
   ```routeros
   /tool fetch url="https://api.telegram.org/bot<TOKEN>/getMe" output=user
   ```
   Debe retornar JSON con datos del bot.

### "DDNS no se actualiza"

**Verificar:**
1. Credenciales cdmon correctas
2. IP pública real cambió (no es local 192.168.x.x)
3. En Terminal:
   ```routeros
   /tool fetch url="http://ipinfo.io/ip" output=user
   ```
   Debe mostrar tu IP pública.

### "Ruta recursiva no se activa (Status = Inactive)"

**Causa**: `target-scope` incorrecto.

**Solución**: En RouterOS 7.20.7+, usar `target-scope=11` (no 0).

```routeros
/ip route set [find dst-address=0.0.0.0/0 gateway~"1.1.1.1"] target-scope=11
```

### "Detecta caídas falsas de WAN"

**Causa**: Gateway configurado no responde bien a ping, o ISP bloquea pings.

**Solución**: Cambiar destino de ping en línea `googleDns`:
```routeros
:local googleDns "8.8.8.8"        # Intenta también 1.1.1.1, 9.9.9.9, etc
```

---

## 📊 Flujo de Ejecución

```
┌─────────────────────────────────────────────────────────────┐
│ SCRIPT INICIA (cada 5 minutos vía scheduler)                │
└─────────────────────────────────────────────────────────────┘
                            ↓
    ┌───────────────────────────────────────────────────┐
    │ PASO 1: CHEQUEO DE CONECTIVIDAD (2 etapas/WAN)    │
    │ ├─ Etapa 1: Link status (cable/modem)             │
    │ └─ Etapa 2: Internet real (ping a 8.8.8.8)        │
    │ Resultado: wan1Status, wan2Status                  │
    └───────────────────────────────────────────────────┘
                            ↓
    ┌───────────────────────────────────────────────────┐
    │ PASO 2: ALERTAS (solo si status cambió)           │
    │ ├─ 🔴 ENLACE CAÍDO → Telegram/WhatsApp            │
    │ └─ 🟠 SIN INTERNET → Telegram/WhatsApp            │
    └───────────────────────────────────────────────────┘
                            ↓
    ┌───────────────────────────────────────────────────┐
    │ PASO 3: ACTUALIZACIÓN DDNS                        │
    │ ├─ Obtener IP registrada en cdmon                 │
    │ ├─ Obtener IP pública actual (ipinfo.io)          │
    │ ├─ Si cambiaron → actualizar en cdmon             │
    │ └─ Si notifyIpChange = true → alertar cambio      │
    └───────────────────────────────────────────────────┘
                            ↓
    ┌───────────────────────────────────────────────────┐
    │ FIN: Espera próxima ejecución (5 min)             │
    └───────────────────────────────────────────────────┘
```

---

## 📝 Comparativa de Versiones

| Aspecto | V1 (PPPoE) | V2 (Dual Estática) | V3 (DHCP/ISP2) |
|---------|-----------|-------------------|----------------|
| **WAN1** | Estática | Estática | Estática |
| **WAN2** | PPPoE dinámico | Estática | DHCP dinámico |
| **IP WAN2** | Del interface | Fija 192.168.20.254 | Extraída de table |
| **Tabla routing** | No | Sí (to-wan2) | Sí (salida_WAN2) |
| **Ping WAN2** | Via interface | Via src-address | Via src-address |
| **Fetch WAN2** | Sin routing | Via src-address | Via src-address |
| **Caso uso** | PPPoE dial-up | Dual fibra estática | Fibra + Starlink DHCP |

---

## 🔐 Seguridad

⚠️ **Este repo es PÚBLICO. Nunca subas:**
- Tokens de Telegram reales
- Chat IDs reales
- Hashes MD5 reales
- API keys reales
- Números de teléfono reales
- Dominios/IPs específicas de clientes

**Antes de usar en producción, reemplaza todos los placeholders:**
- `YOUR_TELEGRAM_BOT_TOKEN` → Tu token real
- `YOUR_TELEGRAM_CHAT_ID` → Tu Chat ID real
- `your_cdmon_username` → Tu usuario cdmon
- `YOUR_CDMON_HASH_MD5` → Tu hash real
- etc.

---

## 📚 Referencias

- [MikroTik RouterOS Scripting](https://wiki.mikrotik.com/wiki/Manual:Scripting)
- [cdmon API Documentación](https://www.cdmon.com)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [ipinfo.io](https://ipinfo.io)
- [RFC 5798 - VRRP (Virtual Router Redundancy Protocol)](https://tools.ietf.org/html/rfc5798)

---

## 👨‍💻 Soporte & Contacto

Desarrollado por **DMZ Sistemas**

- 🌐 [dmz.ar](https://dmz.ar)
- 📱 [WhatsApp: +54 11 7828-5893](https://wa.me/541178285893)
- 📧 Contact via sitio web

---

## 📄 Licencia

Este proyecto es de código abierto. Úsalo libremente, adaptalo a tus necesidades, y comparte mejoras.

---

**Última actualización**: Junio 2026  
**Versión de RouterOS testeada**: 7.20.7 (MIPS)  
**Última revisión**: V3 con routing recursivo estable, alertas sanitizadas
