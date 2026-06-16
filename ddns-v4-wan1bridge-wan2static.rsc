###############################################################################
#  SCRIPT DDNS - VERSIÓN 4: Failover recursivo con WAN1 DHCP + WAN2 estática
#  Orden: 1) chequeo de conectividad  2) alertas  3) actualizacion DDNS
#
#  Caso de uso: WAN1 obtiene IP pública vía DHCP (modem en bridge)
#              WAN2 tiene IP estática configurada
#              DDNS solo en WAN1 (WAN2 deshabilitado)
#
#  Desarrollado por DMZ Sistemas - Brian Tierno
#  https://dmz.ar / https://wa.me/541178285893
###############################################################################

###############################################################################
#  ZONA DE CONFIGURACIÓN - Edita solo esta sección para adaptarlo a tu equipo
###############################################################################

###############################################################################
#  LOG LIMPIO EN PRODUCCIÓN (OPCIONAL)
###############################################################################
#
#  Si deseas un log limpio sin mensajes "Download from ipinfo.io FINISHED",
#  ejecuta ANTES de correr el script:
#
#    /system logging set [find topics~"info"] topics=info,!fetch
#
#  Script ejecuta aquí...
#
#  Y DESPUÉS (en caso de querer restaurar al estado original):
#
#    /system logging set [find topics~"info"] topics=info
#
#  NOTA: El script NO ejecuta estos comandos automáticamente porque generan
#        mensajes en el log que ensuciarian el objetivo de tener log limpio.
#        El admin decide manualmente si aplicarlos.
#
###############################################################################
#  DEBUG: CONTROLAR VERBOSIDAD DE LOGS
###############################################################################
#
#  debugEnabled = true  ? Ves TODOS los mensajes (Debug + Info)
#                         Ideal para troubleshooting, desarrollo, testing
#
#  debugEnabled = false ? Solo ves alertas reales (Warning + Error)
#                         Ideal para PRODUCCIÓN, log limpio
#
###############################################################################

# --- Activar/Desactivar debug en consola ---
:local debugEnabled false

# --- Habilitar/deshabilitar actualizacion de DDNS por WAN ---
# Si está en false, se omite completamente (sin validar ni actualizar)
:local ddns1Enabled true
:local ddns2Enabled false

# --- Avisar cuando cambia la IP publica (alertas DDNS) ---
# IMPORTANTE: el DDNS se actualiza SOLO si el WAN esta UP y ddnsXEnabled=true.
# Esto SOLO controla si se envia notificacion del cambio de IP.
# Las alertas de CAIDA de WAN NO dependen de este parametro (siempre avisan).
:local notifyIpChange false

# --- TELEGRAM ---
:local telegramEnabled true
:local telegramToken "YOUR_TELEGRAM_BOT_TOKEN"
:local telegramChatId "YOUR_TELEGRAM_CHAT_ID"

# --- WHATSAPP (usando textmebot) ---
# Predeterminado en false: la API es sensible al uso masivo de alertas.
:local whatsappEnabled false
:local whatsappPhone "YOUR_WHATSAPP_PHONE"
:local whatsappApiKey "YOUR_WHATSAPP_API_KEY"

# --- DDNS WAN1 (DHCP client) ---
:local ddns1Domain "your-domain.com"
:local ddns1User "YOUR_DDNS_USER"
:local ddns1Hash "YOUR_CDMON_HASH_MD5"

# --- DDNS WAN2 (deshabilitado - IP estática) ---
# Configurar si WAN2 necesita DDNS en el futuro
:local ddns2Domain ""
:local ddns2User ""
:local ddns2Hash ""

# --- Parámetros de red (cambiar según tu topología) ---
:local ipinfoUrl "http://ipinfo.io/ip"
:local ddnsProvider "https://dinamico.cdmon.org/onlineService.php"
:local googleDns "8.8.8.8"
:local pingCount 3

# --- Interfaces de red ---
:local wan1Interface "ether1"
:local wan2Interface "ether2"
:local wan2IpStatic "192.168.1.254"
:local wan2Gateway "192.168.1.1"

###############################################################################
#  ROUTING REQUERIDO PARA WAN2 - CONFIGURAR UNA VEZ EN CADA EQUIPO NUEVO
#  (ajustar IPs segun el equipo).
#
#  Permite que el fetch/ping de WAN2 salga SIEMPRE por ether2 aunque su ruta
#  en la tabla main este en standby (failover por distance).
#
#    /routing table add name=to-wan2 fib comment="Forzar consultas por WAN2"
#    /ip route add dst-address=0.0.0.0/0 gateway=192.168.1.1 routing-table=to-wan2 comment="WAN2 deteccion DDNS"
#    /routing rule add src-address=192.168.1.254 action=lookup table=to-wan2 comment="WAN2 IP detection"
#
#  NO toca el failover (la tabla main queda igual). Solo afecta al trafico
#  originado desde 192.168.1.254 (el fetch/ping de deteccion de WAN2).
###############################################################################

###############################################################################
#  FIN ZONA DE CONFIGURACIÓN - El resto del script no debe modificarse
###############################################################################

:if ($debugEnabled = true) do={ :log info "🔵 INICIANDO SCRIPT DDNS - VERSION 4 (WAN1 DHCP + WAN2 ESTÁTICA)" }

:local DeviceName [/system identity get name]
:if ($debugEnabled = true) do={ :log info ("📱 Equipo detectado: " . $DeviceName) }

# Estados posibles por WAN: "UP" | "LINK_DOWN" | "NO_INET"
:local wan1Status "UP"
:local wan2Status "UP"
:local wan1PublicIP ""
:local wan2PublicIP ""
:local wan1Gateway ""
:local p 0

###############################################################################
# PASO 1 - CHEQUEO DE CONECTIVIDAD (dos etapas por WAN)
###############################################################################
:if ($debugEnabled = true) do={ :log info "🔵 [PASO 1/3] Chequeando conectividad de ambas WANs..." }

# --- WAN1 DHCP (obtener IP y gateway de dhcp-client, luego ping) ---
:set p 0
:do {
  :local ipConMascara [/ip dhcp-client get [find interface=$wan1Interface] address]
  :if ([:len $ipConMascara] > 0) do={
    :set wan1PublicIP [:pick $ipConMascara 0 [:find $ipConMascara "/"]]
    :set wan1Gateway [/ip dhcp-client get [find interface=$wan1Interface] gateway]
    :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN1 DHCP IP: " . $wan1PublicIP . " | Gateway: " . $wan1Gateway) }
  } else={
    :set wan1Status "LINK_DOWN"
    :set wan1PublicIP ""
    :set wan1Gateway ""
  }
} on-error={ :set wan1Status "LINK_DOWN"; :set wan1PublicIP ""; :set wan1Gateway "" }

# Etapa 2 WAN1: ping a gateway (si tenemos IP)
:if ($wan1Status != "LINK_DOWN" and [:len $wan1Gateway] > 0) do={
  :set p 0
  :do { :set p [/ping $wan1Gateway interface=$wan1Interface count=$pingCount] } on-error={ :set p 0 }
  :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN1 etapa2 (gateway " . $wan1Gateway . "): " . $p . " recibidos") }
  :if ($p = 0) do={ :set wan1Status "NO_INET" } else={
    # Etapa 3 WAN1: ping a internet
    :set p 0
    :do { :set p [/ping $googleDns interface=$wan1Interface count=$pingCount] } on-error={ :set p 0 }
    :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN1 etapa3 (internet): " . $p . " recibidos") }
    :if ($p = 0) do={ :set wan1Status "NO_INET" }
  }
}

# --- WAN2 estática (etapa1: ping gateway via ether2; etapa2: ping internet via src-address) ---
:set p 0
:do { :set p [/ping $wan2Gateway interface=$wan2Interface count=$pingCount] } on-error={ :set p 0 }
:if ($debugEnabled = true) do={ :log info ("DEBUG: WAN2 etapa1 (gateway " . $wan2Gateway . "): " . $p . " recibidos") }
:if ($p = 0) do={
  :set wan2Status "LINK_DOWN"
  :set wan2PublicIP ""
} else={
  :set wan2PublicIP $wan2IpStatic
  :set p 0
  :do { :set p [/ping $googleDns src-address=$wan2IpStatic count=$pingCount] } on-error={ :set p 0 }
  :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN2 etapa2 (internet via " . $wan2IpStatic . "): " . $p . " recibidos") }
  :if ($p = 0) do={ :set wan2Status "NO_INET" }
}

###############################################################################
# PASO 2 - ALERTAS DE CAIDA (mensajes distintos; siempre activas)
###############################################################################
:local nowDate [/system clock get date]
:local nowTime [/system clock get time]

# --- WAN1 ---
:local alert1 ""
:if ($wan1Status = "LINK_DOWN") do={
  :log error ("🔴 WAN1 (" . $wan1Interface . ") ENLACE CAIDO - sin DHCP asignada")
  :set alert1 ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20ENLACE%20CAIDO%0ASin%20direccion%20DHCP%20asignada%20%28cable/modem/puerto%29%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan1Status = "NO_INET") do={
  :log error ("🟠 WAN1 (" . $wan1Interface . ") SIN INTERNET - DHCP OK, posible caida ISP")
  :set alert1 ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20SIN%20INTERNET%0ADHCP%20OK%2C%20posible%20caida%20ISP/fibra/nodo%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan1Status = "UP") do={ :if ($debugEnabled = true) do={ :log info ("✅ WAN1 (" . $wan1Interface . ") OK") } }
:if ([:len $alert1] > 0) do={
  :if ($telegramEnabled = true) do={
    :do { /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $alert1) keep-result=no } on-error={ :log warning "⚠️ Error Telegram WAN1" }
  }
  :if ($whatsappEnabled = true) do={
    :do { /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $alert1) keep-result=no } on-error={ :log warning "⚠️ Error WhatsApp WAN1" }
  }
}

# --- WAN2 ---
:local alert2 ""
:if ($wan2Status = "LINK_DOWN") do={
  :log error ("🔴 WAN2 (" . $wan2Interface . ") ENLACE CAIDO - sin link al modem")
  :set alert2 ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20ENLACE%20CAIDO%0ASin%20enlace%20al%20modem%20%28cable/modem/puerto%29%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan2Status = "NO_INET") do={
  :log error ("🟠 WAN2 (" . $wan2Interface . ") SIN INTERNET - modem OK, posible caida ISP")
  :set alert2 ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20SIN%20INTERNET%0AModem%20OK%2C%20posible%20caida%20ISP/fibra/nodo%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan2Status = "UP") do={ :if ($debugEnabled = true) do={ :log info ("✅ WAN2 (" . $wan2Interface . ") OK") } }
:if ([:len $alert2] > 0) do={
  :if ($telegramEnabled = true) do={
    :do { /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $alert2) keep-result=no } on-error={ :log warning "⚠️ Error Telegram WAN2" }
  }
  :if ($whatsappEnabled = true) do={
    :do { /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $alert2) keep-result=no } on-error={ :log warning "⚠️ Error WhatsApp WAN2" }
  }
}

###############################################################################
# PASO 3 - ACTUALIZAR DDNS (solo para las WAN que estan UP)
###############################################################################

# --- WAN1 (DHCP - solo si DDNS habilitado) ---
:if (($wan1Status = "UP") and ($ddns1Enabled = true)) do={
  :if ($debugEnabled = true) do={ :log info ("🔄 [PASO 3/3] Procesando DDNS de WAN1 (" . $ddns1Domain . ")...") }
  :do {
    :set wan1PublicIP ([/tool fetch url=$ipinfoUrl src-address=$wan1PublicIP output=user as-value]->"data")
    :if ($debugEnabled = true) do={ :log info ("DEBUG: IP publica WAN1 (verificada): " . $wan1PublicIP) }
  } on-error={ :log error "❌ ERROR obteniendo IP publica de WAN1"; :set wan1PublicIP "" }

  :if ([:len $wan1PublicIP] > 0) do={
    :local OldIp1 ""
    :do {
      # Obtener IP registrada en cdmon (via API, no :resolve que puede devolver DNS local)
      :local ddnsResponse ([/tool fetch url=("https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash) output=user as-value]->"data")
      :local s ([:find $ddnsResponse "newip="] + 6)
      :if ($s >= 6) do={ :set OldIp1 [:pick $ddnsResponse $s [:find $ddnsResponse "&" $s]] }
    } on-error={ :set OldIp1 "" }
    :if ($debugEnabled = true) do={ :log info ("DEBUG: IP registrada en cdmon WAN1: " . $OldIp1) }
    
    :if ($wan1PublicIP = $OldIp1) do={
      :if ($debugEnabled = true) do={ :log info ("✅ WAN1 sin cambios - IP actual: " . $wan1PublicIP) }
    } else={
      :log warning ("⚠️ WAN1 CAMBIO - Anterior: " . $OldIp1 . " -> Nueva: " . $wan1PublicIP)
      :do {
        :if ($debugEnabled = true) do={ :log info ("DEBUG URL DDNS WAN1: " . $ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $wan1PublicIP) }
        /tool fetch url=($ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $wan1PublicIP) keep-result=no
        :if ($debugEnabled = true) do={ :log info ("✅ DDNS WAN1 actualizado para " . $DeviceName) }
        :if ($notifyIpChange = true) do={
          :local msg ("%F0%9F%94%84%20%5B" . $DeviceName . "%5D%20WAN1%20CAMBIO%0AIP%20anterior:%20" . $OldIp1 . "%0AIP%20nueva:%20" . $wan1PublicIP . "%0ADominio:%20" . $ddns1Domain)
          :if ($telegramEnabled = true) do={ :do { /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error Telegram cambio WAN1" } }
          :if ($whatsappEnabled = true) do={ :do { /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error WhatsApp cambio WAN1" } }
        }
      } on-error={ :log error "❌ Error actualizando DDNS WAN1" }
    }
  }
} else={
  :if ($ddns1Enabled = false) do={ :if ($debugEnabled = true) do={ :log info ("⏭️  WAN1 DDNS deshabilitado") } }
  :if ($wan1Status != "UP") do={ :log warning ("⚠️ WAN1 no esta UP (" . $wan1Status . "), se omite DDNS WAN1") }
}

# --- WAN2 (DDNS siempre deshabilitado en V4) ---
:if ($ddns2Enabled = false) do={
  :if ($debugEnabled = true) do={ :log info ("⏭️  WAN2 DDNS deshabilitado (IP estática)") }
}

###############################################################################
# RESUMEN FINAL
###############################################################################
:if ($debugEnabled = true) do={ :log info "-----------------------------------------------" }
:if ($debugEnabled = true) do={ :log info ("✅ SCRIPT COMPLETADO - Equipo: " . $DeviceName) }
:if ($debugEnabled = true) do={ :log info ("🔵 WAN1 [" . $wan1Status . "]: " . $wan1PublicIP . " | WAN2 [" . $wan2Status . "]: " . $wan2PublicIP) }
:if ($debugEnabled = true) do={ :log info "-----------------------------------------------" }
