###############################################################################
#  SCRIPT DDNS - VERSIÓN 1: Failover recursivo WAN1 estática + WAN2 PPPoE
#  Orden: 1) chequeo de conectividad  2) alertas  3) actualizacion DDNS
#  Con ZONA DE CONFIGURACIÓN centralizada para reutilizar en otros equipos
#
#  Desarrollado por DMZ Sistemas — Brian Tierno
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
#  debugEnabled = true  → Ves TODOS los mensajes (Debug + Info)
#                         Ideal para troubleshooting, desarrollo, testing
#
#  debugEnabled = false → Solo ves alertas reales (Warning + Error)
#                         Ideal para PRODUCCIÓN, log limpio
#
###############################################################################

# --- Activar/Desactivar debug en consola ---
:local debugEnabled false

# --- Avisar cuando cambia la IP publica (alertas DDNS) ---
# IMPORTANTE: el DDNS SIEMPRE se actualiza aunque esto este en false.
# Esto SOLO controla si se envia notificacion del cambio de IP.
# Las alertas de CAIDA de WAN NO dependen de este parametro (siempre avisan).
:local notifyIpChange false

# --- TELEGRAM ---
:local telegramEnabled true
:local telegramToken "TU_BOT_TOKEN_AQUI"
:local telegramChatId "TU_CHAT_ID_AQUI"

# --- WHATSAPP (usando textmebot) ---
# Predeterminado en false: la API es sensible al uso masivo de alertas.
:local whatsappEnabled false
:local whatsappPhone "+54XXXXXXXXXX"
:local whatsappApiKey "TU_API_KEY_AQUI"

# --- DDNS WAN1 (tudominio.com) ---
:local ddns1Domain "tudominio.com"
:local ddns1User "TU_USUARIO_DDNS"
:local ddns1Hash "TU_HASH_MD5_AQUI"
:local ddns1SourceIP "192.168.10.254"

# --- DDNS WAN2 (vpn.tudominio.com) PPPoE ---
:local ddns2Domain "vpn.tudominio.com"
:local ddns2User "TU_USUARIO_DDNS_WAN2"
:local ddns2Hash "TU_HASH_MD5_WAN2_AQUI"
# PPPoE: el interface es ppp-out1, la IP se obtiene directo del interface
:local wan2Interface "ppp-out1"

# --- Parámetros de red (cambiar solo si es necesario) ---
:local ipinfoUrl "http://ipinfo.io/ip"
:local ddnsProvider "https://dinamico.cdmon.org/onlineService.php"
:local googleDns "8.8.8.8"
:local pingCount 3

# --- Interfaces de red ---
:local wan1Interface "ether1"
:local wan1Gateway "192.168.10.1"

###############################################################################
#  ROUTING REQUERIDO PARA WAN1 - CONFIGURAR UNA VEZ EN CADA EQUIPO NUEVO
#  WAN2 (PPPoE) no necesita routing especial (es tunnel directo con IP pública)
#
#    /routing table add name=to-wan1 fib comment="Forzar consultas por WAN1"
#    /ip route add dst-address=1.1.1.1/32 gateway=192.168.10.1 scope=10 comment="WAN1 probe recursivo"
#    /ip route add dst-address=0.0.0.0/0 gateway=1.1.1.1 target-scope=11 distance=1 check-gateway=ping comment="WAN1 default recursivo"
#
#  WAN2 (PPPoE) usa ruta default plana:
#    /ip route add dst-address=0.0.0.0/0 gateway=ppp-out1 distance=2 comment="WAN2 default PPPoE"
#
#  Nota: con PPPoE, la ruta se activa automáticamente cuando el tunnel conecta.
###############################################################################

###############################################################################
#  FIN ZONA DE CONFIGURACIÓN - El resto del script no debe modificarse
###############################################################################

:if ($debugEnabled = true) do={ :log info "🔵 INICIANDO SCRIPT DDNS - VERSION 1 (CON PPPoE)" }

:local DeviceName [/system identity get name]
:if ($debugEnabled = true) do={ :log info ("📱 Equipo detectado: " . $DeviceName) }

# Estados posibles por WAN: "UP" | "LINK_DOWN" | "NO_INET"
:local wan1Status "UP"
:local wan2Status "UP"
:local CurrentIP ""
:local PublicIP ""
:local p 0

###############################################################################
# PASO 1 - CHEQUEO DE CONECTIVIDAD (dos etapas por WAN)
###############################################################################
:if ($debugEnabled = true) do={ :log info "🔄 [PASO 1/3] Chequeando conectividad de ambas WANs..." }

# --- WAN1 (ether1 estática, recursivo) ---
:set p 0
:do { :set p [/ping $wan1Gateway interface=$wan1Interface count=$pingCount] } on-error={ :set p 0 }
:if ($debugEnabled = true) do={ :log info ("DEBUG: WAN1 etapa1 (gateway " . $wan1Gateway . "): " . $p . " recibidos") }
:if ($p = 0) do={
  :set wan1Status "LINK_DOWN"
} else={
  :set p 0
  :do { :set p [/ping $googleDns interface=$wan1Interface count=$pingCount] } on-error={ :set p 0 }
  :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN1 etapa2 (internet): " . $p . " recibidos") }
  :if ($p = 0) do={ :set wan1Status "NO_INET" }
}

# --- WAN2 (PPPoE) - Una etapa: interface running + internet ---
:if ([/interface get [find name=$wan2Interface] running] = false) do={
  :set wan2Status "LINK_DOWN"
  :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN2 (ppp-out1) link DOWN") }
} else={
  :set p 0
  :do { :set p [/ping $googleDns interface=$wan2Interface count=$pingCount] } on-error={ :set p 0 }
  :if ($debugEnabled = true) do={ :log info ("DEBUG: WAN2 etapa1 (internet via ppp-out1): " . $p . " recibidos") }
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
  :log error ("🔴 WAN1 (" . $wan1Interface . ") ENLACE CAIDO - sin link al modem")
  :set alert1 ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20ENLACE%20CAIDO%0ASin%20enlace%20al%20modem%20%28cable/modem/puerto%29%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan1Status = "NO_INET") do={
  :log error ("🟠 WAN1 (" . $wan1Interface . ") SIN INTERNET - modem OK, posible caida ISP")
  :set alert1 ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20SIN%20INTERNET%0AModem%20OK%2C%20posible%20caida%20ISP/fibra/nodo%0AHora:%20" . $nowDate . "%20" . $nowTime)
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

# --- WAN2 (PPPoE) ---
:local alert2 ""
:if ($wan2Status = "LINK_DOWN") do={
  :log error ("🔴 WAN2 (" . $wan2Interface . ") TUNNEL CAIDO - PPPoE desconectado")
  :set alert2 ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20TUNNEL%20CAIDO%0APPPOE%20desconectado%0AHora:%20" . $nowDate . "%20" . $nowTime)
}
:if ($wan2Status = "NO_INET") do={
  :log error ("🟠 WAN2 (" . $wan2Interface . ") SIN INTERNET - tunnel OK, posible caida ISP")
  :set alert2 ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20SIN%20INTERNET%0ATunel%20OK%2C%20posible%20caida%20ISP%0AHora:%20" . $nowDate . "%20" . $nowTime)
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

# --- WAN1 (ether1 estática, fetch ipinfo.io) ---
:if ($wan1Status = "UP") do={
  :if ($debugEnabled = true) do={ :log info ("🔄 [PASO 3/3] Procesando DDNS de WAN1 (" . $ddns1Domain . ")...") }
  :do {
    :set CurrentIP ([/tool fetch url=$ipinfoUrl src-address=$ddns1SourceIP output=user as-value]->"data")
    :if ($debugEnabled = true) do={ :log info ("DEBUG: IP publica WAN1: " . $CurrentIP) }
  } on-error={ :log error "❌ ERROR obteniendo IP de WAN1"; :set CurrentIP "" }

  :if ([:len $CurrentIP] > 0) do={
    :local OldIp1 ""
    :do { :set OldIp1 ([:resolve $ddns1Domain]) } on-error={ :set OldIp1 "" }
    :if ($CurrentIP = $OldIp1) do={
      :if ($debugEnabled = true) do={ :log info ("✅ WAN1 sin cambios - IP actual: " . $CurrentIP) }
    } else={
      :log warning ("⚠️ WAN1 CAMBIO - Anterior: " . $OldIp1 . " -> Nueva: " . $CurrentIP)
      :do {
        :if ($debugEnabled = true) do={ :log info ("DEBUG URL DDNS WAN1: " . $ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $CurrentIP) }
        /tool fetch url=($ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $CurrentIP) keep-result=no
        :if ($debugEnabled = true) do={ :log info ("✅ DDNS WAN1 actualizado para " . $DeviceName) }
        :if ($notifyIpChange = true) do={
          :local msg ("%F0%9F%94%84%20%5B" . $DeviceName . "%5D%20WAN1%20CAMBIO%0AIP%20anterior:%20" . $OldIp1 . "%0AIP%20nueva:%20" . $CurrentIP . "%0ADominio:%20" . $ddns1Domain)
          :if ($telegramEnabled = true) do={ :do { /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error Telegram cambio WAN1" } }
          :if ($whatsappEnabled = true) do={ :do { /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error WhatsApp cambio WAN1" } }
        }
      } on-error={ :log error "❌ Error actualizando DDNS WAN1" }
    }
  }
} else={
  :log warning ("⚠️ WAN1 no esta UP (" . $wan1Status . "), se omite DDNS WAN1")
}

# --- WAN2 (PPPoE - IP se lee del interface) ---
:if ($wan2Status = "UP") do={
  :if ($debugEnabled = true) do={ :log info ("🔄 [PASO 3/3] Procesando DDNS de WAN2 (" . $ddns2Domain . ")...") }
  :do {
    # PPPoE asigna IP pública directo al interface. Se lee: /ip address get [find interface=ppp-out1] address
    # Ejemplo: "1.2.3.4/32" — necesita extraer solo la IP sin /32
    :local wan2IpRaw ""
    :do { :set wan2IpRaw [/ip address get [find interface=$wan2Interface] address] } on-error={ :set wan2IpRaw "" }
    :if ([:len $wan2IpRaw] > 0) do={
      # Extraer IP sin máscara: tomar desde inicio hasta "/"
      :set PublicIP [:pick $wan2IpRaw 0 [:find $wan2IpRaw "/"]]
    } else={
      :set PublicIP ""
    }
    :if ($debugEnabled = true) do={ :log info ("DEBUG: IP publica WAN2 (del interface ppp-out1): " . $PublicIP) }
  } on-error={ :log error "❌ ERROR obteniendo IP de WAN2"; :set PublicIP "" }

  :if ([:len $PublicIP] > 0) do={
    :local OldIp2 ""
    :do { :set OldIp2 ([:resolve $ddns2Domain]) } on-error={ :set OldIp2 "" }
    :if ($PublicIP = $OldIp2) do={
      :if ($debugEnabled = true) do={ :log info ("✅ WAN2 sin cambios - IP actual: " . $PublicIP) }
    } else={
      :log warning ("⚠️ WAN2 CAMBIO - Anterior: " . $OldIp2 . " -> Nueva: " . $PublicIP)
      :do {
        :if ($debugEnabled = true) do={ :log info ("DEBUG URL DDNS WAN2: " . $ddnsProvider . "?enctype=MD5&n=" . $ddns2User . "&p=" . $ddns2Hash . "&cip=" . $PublicIP) }
        /tool fetch url=($ddnsProvider . "?enctype=MD5&n=" . $ddns2User . "&p=" . $ddns2Hash . "&cip=" . $PublicIP) keep-result=no
        :if ($debugEnabled = true) do={ :log info ("✅ DDNS WAN2 actualizado para " . $DeviceName) }
        :if ($notifyIpChange = true) do={
          :local msg ("%F0%9F%94%84%20%5B" . $DeviceName . "%5D%20WAN2%20CAMBIO%0AIP%20anterior:%20" . $OldIp2 . "%0AIP%20nueva:%20" . $PublicIP . "%0ADominio:%20" . $ddns2Domain)
          :if ($telegramEnabled = true) do={ :do { /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error Telegram cambio WAN2" } }
          :if ($whatsappEnabled = true) do={ :do { /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $msg) keep-result=no } on-error={ :log warning "⚠️ Error WhatsApp cambio WAN2" } }
        }
      } on-error={ :log error "❌ Error actualizando DDNS WAN2" }
    }
  }
} else={
  :log warning ("⚠️ WAN2 no esta UP (" . $wan2Status . "), se omite DDNS WAN2")
}

###############################################################################
# RESUMEN FINAL
###############################################################################
:if ($debugEnabled = true) do={ :log info "═══════════════════════════════════════════════" }
:if ($debugEnabled = true) do={ :log info ("✅ SCRIPT COMPLETADO - Equipo: " . $DeviceName) }
:if ($debugEnabled = true) do={ :log info ("📊 WAN1 [" . $wan1Status . "]: " . $CurrentIP . " | WAN2 [" . $wan2Status . "]: " . $PublicIP) }
:if ($debugEnabled = true) do={ :log info "═══════════════════════════════════════════════" }
