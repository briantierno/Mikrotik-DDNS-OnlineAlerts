# ============================================================================
#  DMZ Sistemas - ZONA DE CONFIGURACION           dmz-config.rsc   v1.0
#  Este es el UNICO archivo que se edita por sitio.
#  El motor (dmz-engine.rsc) es igual para todos y no se toca.
#
#  PLANTILLA: copiar a dmz-config.rsc y editar esa copia. dmz-config.rsc
#  esta en .gitignore: los datos reales del sitio NUNCA van al repo.
#
#  Uso:   /import dmz-config.rsc        (carga variables, no aplica nada)
#         /import dmz-engine.rsc        (valida y aplica)
#
#  Familia soportada: equipos con paquete "wireless" (hAP ac, cAP ac, hEX+AP).
#  Los equipos ax (/interface wifi) NO estan soportados por este template.
# ============================================================================

# ----------------------------------------------------------------------------
#  IDENTIDAD
# ----------------------------------------------------------------------------
:global cfgSiteName        "cliente"              ;# slug corto, sin espacios
:global cfgIdentity        "MikroTik-Cliente"
:global cfgTimeZone        "America/Argentina/Buenos_Aires"
:global cfgAdminPassword   ""                    ;# vacio = no cambia la actual

# ----------------------------------------------------------------------------
#  LAN   (siempre se configura)
#  Se indican los 3 primeros octetos. El motor deriva:
#     gateway/DNS = .1    pool = .10 - .254    DHCP en el bridge
# ----------------------------------------------------------------------------
:global cfgLanNet          "192.168.88"
:global cfgLanDnsUpstream  "9.9.9.9"
:global cfgLanLeaseTime    "2h"

# ----------------------------------------------------------------------------
#  WAN1
#    cfgWan1Mode: "static" | "dhcp" | "none"
#    En static, cfgWan1Ip es la IP del MikroTik y cfgWan1Gw la del modem.
#    La sonda es la IP que se clava a esta WAN para el failover recursivo.
# ----------------------------------------------------------------------------
:global cfgWan1Mode        "static"
:global cfgWan1Iface       "ether1"
:global cfgWan1Ip          "192.168.17.2/24"
:global cfgWan1Gw          "192.168.17.1"
:global cfgWan1Probe       "1.1.1.1"

# ----------------------------------------------------------------------------
#  WAN2   (opcional - failover)
#  Con cfgWan2Mode="none" no se crea nada y WAN1 queda como unica salida.
# ----------------------------------------------------------------------------
:global cfgWan2Mode        "static"
:global cfgWan2Iface       "ether2"
:global cfgWan2Ip          "192.168.18.2/24"
:global cfgWan2Gw          "192.168.18.1"
:global cfgWan2Probe       "8.8.4.4"

# ----------------------------------------------------------------------------
#  WIFI LAN   (red interna, sin hotspot)
# ----------------------------------------------------------------------------
:global cfgWifi            true
:global cfgWifiSsid24      "MiRed 2.4GHz"
:global cfgWifiSsid5       "MiRed 5GHz"
:global cfgWifiPassword    "CAMBIAR_CLAVE_WIFI"
:global cfgWifiCountry     "argentina"

# ----------------------------------------------------------------------------
#  HOTSPOT   (VLAN propia sobre el mismo bridge, aislado de la LAN)
#  Red: solo los 3 primeros octetos, igual que la LAN. Debe ser != cfgLanNet.
#  El html va subido a mano a la carpeta que indique cfgHsHtmlDir.
# ----------------------------------------------------------------------------
:global cfgHotspot         false
:global cfgHsNet           "192.168.25"
:global cfgHsVlanId        25
:global cfgHsIface         "ether5"              ;# puerto cableado del hotspot
:global cfgHsSsid          "WiFi Clientes"
:global cfgHsDnsName       "wifi.cliente.ejemplo.com"
:global cfgHsHtmlDir       "hotspot"             ;# en algunos modelos: flash/hotspot
:global cfgHsLoginBy       "cookie,http-chap,trial"
:global cfgHsTrialUptime   "1h"
:global cfgHsTrialReset    "4h"
:global cfgHsAdminPassword ""
:global cfgHsWalledGarden  ""              ;# hosts separados por coma, "" = ninguno

# ----------------------------------------------------------------------------
#  WIREGUARD hacia el servidor DMZ
#  El motor GENERA un par de claves nuevo y deja la public-key en el log:
#     /log print where message~"WIREGUARD"
#  Esa clave se pega como peer en dmz.ar. No se reusa la key de otro sitio.
# ----------------------------------------------------------------------------
:global cfgWireGuard       true
:global cfgWgEndpoint      "vpn.ejemplo.com"
:global cfgWgEndpointPort  51825
:global cfgWgKeepalive     "25s"
:global cfgWgServerPubKey  "PUBLIC_KEY_DEL_SERVIDOR"
:global cfgWgLocalIp       "10.0.0.X/24"         ;# IP de ESTE sitio en la VPN
:global cfgWgAllowed       "10.0.0.0/24,192.168.8.0/24"
:global cfgWgRemoteNets    "192.168.8.0/24"      ;# rutas hacia el otro lado

# ----------------------------------------------------------------------------
#  WAN MONITOR   (se descarga del repo; requiere salida a internet al aplicar)
# ----------------------------------------------------------------------------
:global cfgWanMonitor      false
:global cfgWmDebug         false
:global cfgWmNotifyIpChange false
:global cfgWmUrl           "https://raw.githubusercontent.com/briantierno/Mikrotik-DDNS-OnlineAlerts/main/wan-monitor.rsc"
:global cfgWmInterval      "5m"
:global cfgWmTelegram      true
:global cfgWmTgToken       ""
:global cfgWmTgChatId      ""
:global cfgWmWhatsapp      true
:global cfgWmWaPhone       ""
:global cfgWmWaApiKey      ""
:global cfgWmDdns          false
:global cfgWmDdnsDomain    ""
:global cfgWmDdnsUser      ""
:global cfgWmDdnsHash      ""

# ----------------------------------------------------------------------------
#  PORT FORWARDING   (opcional) - "" = ninguno
#  Formato: puerto:ip:puertoDestino:protocolo , separados por coma
#  Ej: "80:192.168.15.200:80:tcp,443:192.168.15.200:443:tcp"
# ----------------------------------------------------------------------------
:global cfgPortForward     ""

# ----------------------------------------------------------------------------
#  LEASES FIJOS   (opcional) - "" = ninguno
#  Formato: mac|ip|comentario , separados por coma
#  Ej: "78:2B:CB:98:F8:1E|192.168.15.200|Servidor"
# ----------------------------------------------------------------------------
:global cfgStaticLeases    ""

# ----------------------------------------------------------------------------
#  DNS ESTATICO   (opcional) - "" = ninguno
#  Formato: nombre|ip , separados por coma
# ----------------------------------------------------------------------------
:global cfgStaticDns       ""

:log warning "[DMZ-CONFIG] Variables cargadas. Ahora: /import dmz-engine.rsc"
