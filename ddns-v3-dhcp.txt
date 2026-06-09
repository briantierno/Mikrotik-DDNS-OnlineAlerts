###############################################################################
#  SCRIPT DDNS - VERSIÓN 3: Failover recursivo con WAN1 estática + WAN2 DHCP
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

# --- DDNS WAN2: DESHABILITADO (ISP2 podría ser CGNAT actual) ---
# CGNAT (Carrier Grade NAT): No proporciona IP pública configurable.
# Cambiar a true SOLO si:
#  - Cambias a ISP2 con IP pública directa
#  - O cambias a otro proveedor con IP pública asignada
#  - O usas portforwarding/DMZ en el modem
:local wan2DdnsEnabled false
:local ddns2Domain "vpn.tudominio.com"
:local ddns2User "TU_USUARIO_DDNS_WAN2"
:local ddns2Hash "TU_HASH_MD5_AQUI"

# --- Gateway de WAN1 (modem/router del lado de ether1) ---
:local wan1Gateway "192.168.10.1"

# --- Parámetros de red (cambiar solo si es necesario) ---
:local googleDns "8.8.8.8"
:local pingCount 3

# --- Interfaces de red ---
:local wan1Interface "ether1::ISP1"
:local wan2Interface "ether2::ISP2"

# --- Tabla de routing para WAN2 ---
:local wan2RoutingTable "salida_WAN2"

# --- URL para obtener IP pública ---
:local ipinfoUrl "http://ipinfo.io/ip"

###############################################################################
#  ROUTING REQUERIDO PARA WAN1 RECURSIVO - CONFIGURAR UNA VEZ EN CADA EQUIPO
#  (ajustar IPs según el equipo). Necesario para detectar cortes de fibra.
#
#  Permite que WAN1 failovee cuando la fibra cae (no solo cuando el modem cae).
#
#    /ip route add dst-address=1.1.1.1/32 gateway=192.168.10.1 scope=10 comment="WAN1 probe recursivo"
#    /ip route add dst-address=0.0.0.0/0 gateway=1.1.1.1 target-scope=11 distance=1 check-gateway=ping comment="WAN1 default recursivo"
#
###############################################################################

# --- IMPORTANTE: Variables internas, NO EDITAR ---
:local wan1Status ""
:local wan2Status ""
:local wan1PublicIP ""
:local wan2PublicIP ""
:local wan1PublicIPOld ""
:local wan2PublicIPOld ""

# --- Datos del equipo y momento (para alertas) ---
:local DeviceName [/system identity get name]
:local nowDate [/system clock get date]
:local nowTime [/system clock get time]
:if ($debugEnabled = true) do={ :log info ("📱 Equipo detectado: " . $DeviceName) }

# --- Obtener IP actual de WAN2 (DHCP dinámico) para usar en src-address ---
:local wan2CurrentLocalIP ""
:do {
    :local wan2IpRaw [/ip address get [find interface=$wan2Interface] address]
    :set wan2CurrentLocalIP [:pick $wan2IpRaw 0 [:find $wan2IpRaw "/"]]
} on-error={
    :if ($debugEnabled = true) do={ :log error "ERROR: No se pudo obtener IP local de WAN2" }
}

# --- Obtener IP local de WAN1 (ether1::ISP1) para usar en src-address ---
:local wan1CurrentLocalIP ""
:do {
    :local wan1IpRaw [/ip address get [find interface=$wan1Interface] address]
    :set wan1CurrentLocalIP [:pick $wan1IpRaw 0 [:find $wan1IpRaw "/"]]
} on-error={
    :if ($debugEnabled = true) do={ :log error "ERROR: No se pudo obtener IP local de WAN1" }
}

###############################################################################
#  FUNCIONES AUXILIARES
###############################################################################

# Envia alerta a Telegram/WhatsApp. El parametro $1 (msgEnc) DEBE venir
# URL-encoded (%F0%9F... para emojis, %20 espacio, %0A salto de linea).
# Concatena con "." igual que V2 para no romper el encoding.
:local funcSendAlert do={
    :local msgEnc $1

    :if ($telegramEnabled = true) do={
        :do {
            /tool fetch url=("https://api.telegram.org/bot" . $telegramToken . "/sendMessage?chat_id=" . $telegramChatId . "&text=" . $msgEnc) keep-result=no
        } on-error={ :log warning "⚠️ Error Telegram" }
    }

    :if ($whatsappEnabled = true) do={
        :do {
            /tool fetch url=("http://api.textmebot.com/send.php?recipient=" . $whatsappPhone . "&apikey=" . $whatsappApiKey . "&text=" . $msgEnc) keep-result=no
        } on-error={ :log warning "⚠️ Error WhatsApp" }
    }
}

###############################################################################
#  PASO 1: CHEQUEO DE CONECTIVIDAD - ETAPA 1 (ENLACE)
###############################################################################

:if ($debugEnabled = true) do={ :log info "═══════════════════════════════════════════════" }
:if ($debugEnabled = true) do={ :log info "PASO 1: Chequeo de conectividad (ETAPA 1 - ENLACE)" }

# --- WAN1: Ping a gateway local (ISP1) ---
:local wan1LinkOk false
:do {
    :if ([/ping interface=$wan1Interface $wan1Gateway count=$pingCount] > 0) do={
        :set wan1LinkOk true
    }
} on-error={}

:if ($debugEnabled = true) do={ :log info "WAN1 enlace: $wan1LinkOk" }

# --- WAN2: Verificar si interface DHCP tiene address asignada (ISP2) ---
:local wan2LinkOk false
:do {
    :local wan2Address [/ip address get [find interface=$wan2Interface] address]
    :if ([$wan2Address] != "") do={
        :set wan2LinkOk true
    }
} on-error={}

:if ($debugEnabled = true) do={ :log info "WAN2 enlace (DHCP): $wan2LinkOk" }

# --- Determinar status de enlace ---
:if ($wan1LinkOk = false) do={
    :set wan1Status "LINK_DOWN"
    :log error ("🔴 WAN1 (" . $wan1Interface . ") ENLACE CAIDO - sin link al modem")
} else={
    :set wan1Status "UP"
}

:if ($wan2LinkOk = false) do={
    :set wan2Status "LINK_DOWN"
    :log error ("🔴 WAN2 (" . $wan2Interface . ") ENLACE CAIDO - sin address DHCP")
} else={
    :set wan2Status "UP"
}

###############################################################################
#  PASO 1: CHEQUEO DE CONECTIVIDAD - ETAPA 2 (INTERNET)
###############################################################################

:if ($debugEnabled = true) do={ :log info "PASO 1: Chequeo de conectividad (ETAPA 2 - INTERNET)" }

# --- WAN1: Si enlace OK, chequear internet real ---
:if ($wan1Status = "UP") do={
    :local wan1InetOk false
    :do {
        :if ([/ping interface=$wan1Interface $googleDns count=$pingCount] > 0) do={
            :set wan1InetOk true
        }
    } on-error={}
    
    :if ($wan1InetOk = false) do={
        :set wan1Status "NO_INET"
        :log error ("🟠 WAN1 (" . $wan1Interface . ") SIN INTERNET - modem OK, posible caida ISP")
    }
}

# --- WAN2: Si enlace OK, chequear internet real ---
:if ($wan2Status = "UP") do={
    :local wan2InetOk false
    :do {
        # Ping con src-address = IP pública dinámica de ISP2 (obtenida de address table)
        # El destino va PRIMERO, luego src-address
        :if ([/ping $googleDns src-address=$wan2CurrentLocalIP count=$pingCount] > 0) do={
            :set wan2InetOk true
        }
    } on-error={}
    
    :if ($wan2InetOk = false) do={
        :set wan2Status "NO_INET"
        :log error ("🟠 WAN2 (" . $wan2Interface . ") SIN INTERNET - modem OK, posible caida ISP")
    }
}

:if ($debugEnabled = true) do={ :log info "WAN1 status final: $wan1Status | WAN2 status final: $wan2Status" }

###############################################################################
#  PASO 2: ALERTAS (mensajes URL-encoded para Telegram/WhatsApp)
###############################################################################

:if ($debugEnabled = true) do={ :log info "PASO 2: Enviando alertas (si aplica)" }

# --- WAN1 ---
:if ($wan1Status = "LINK_DOWN") do={
    :local alertEnc ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20ENLACE%20CAIDO%0ASin%20enlace%20al%20modem%20%28cable/modem/puerto%29%0AHora:%20" . $nowDate . "%20" . $nowTime)
    [$funcSendAlert $alertEnc]
}
:if ($wan1Status = "NO_INET") do={
    :local alertEnc ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN1%20%28" . $wan1Interface . "%29%20SIN%20INTERNET%0AModem%20OK%2C%20posible%20caida%20ISP/fibra/nodo%0AHora:%20" . $nowDate . "%20" . $nowTime)
    [$funcSendAlert $alertEnc]
}

# --- WAN2 ---
:if ($wan2Status = "LINK_DOWN") do={
    :local alertEnc ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20ENLACE%20CAIDO%0ASin%20enlace%20al%20modem%20%28cable/modem/puerto%29%0AHora:%20" . $nowDate . "%20" . $nowTime)
    [$funcSendAlert $alertEnc]
}
:if ($wan2Status = "NO_INET") do={
    :local alertEnc ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN2%20%28" . $wan2Interface . "%29%20SIN%20INTERNET%0AModem%20OK%2C%20posible%20caida%20ISP/fibra/nodo%0AHora:%20" . $nowDate . "%20" . $nowTime)
    [$funcSendAlert $alertEnc]
}

###############################################################################
#  PASO 3: ACTUALIZAR DDNS (solo para WANs UP)
###############################################################################

:if ($debugEnabled = true) do={ :log info "PASO 3: Actualización DDNS" }

# --- WAN1: Consultar IP registrada en cdmon y actualizar si cambió ---
:if ($wan1Status = "UP") do={
    :if ($debugEnabled = true) do={ :log info "Consultando DDNS WAN1 en cdmon..." }
    
    :local wan1DdnsResponse ""
    :do {
        :set wan1DdnsResponse ([/tool fetch url=("https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash) output=user as-value]->"data")
    } on-error={
        :log error "ERROR DDNS WAN1: No se pudo consultar cdmon"
    }
    
    # Parsear respuesta: buscar "newip=XXXX&..."
    :local wan1RegisteredIP ""
    :if ([:len $wan1DdnsResponse] > 0) do={
        :local s ([:find $wan1DdnsResponse "newip="] + 6)
        :set wan1RegisteredIP [:pick $wan1DdnsResponse $s [:find $wan1DdnsResponse "&" $s]]
    }
    
    # Obtener IP pública actual via ipinfo.io (patrón probado de V2)
    :local wan1CurrentIP ""
    :do {
        :set wan1CurrentIP ([/tool fetch url=$ipinfoUrl src-address=$wan1CurrentLocalIP output=user as-value]->"data")
    } on-error={
        :log error "ERROR DDNS WAN1: No se pudo obtener IP pública de ipinfo.io"
    }
    
    :if ($debugEnabled = true) do={ :log info "WAN1 - IP registrada: $wan1RegisteredIP | IP actual: $wan1CurrentIP" }
    
    # Actualizar DDNS si la IP cambió
    :if ($wan1CurrentIP != "" && $wan1CurrentIP != $wan1RegisteredIP) do={
        :do {
            /tool fetch url=("https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $wan1CurrentIP) keep-result=no
            :if ($debugEnabled = true) do={ :log info "✅ DDNS WAN1 actualizado: $wan1RegisteredIP → $wan1CurrentIP" }
        } on-error={
            :log error "ERROR DDNS WAN1: Fallo al actualizar en cdmon"
        }
    } else={
        :if ($debugEnabled = true) do={ :log info "WAN1 sin cambios de IP, DDNS no actualizado" }
    }
} else={
    :if ($debugEnabled = true) do={ :log info "WAN1 no está UP, saltando actualización DDNS" }
}

# --- WAN2: Consultar IP registrada en cdmon y actualizar si cambió (si está habilitado) ---
:if ($wan2Status = "UP" && $wan2DdnsEnabled = true) do={
    :if ($debugEnabled = true) do={ :log info "Consultando DDNS WAN2 en cdmon..." }
    
    :local wan2DdnsResponse ""
    :do {
        :set wan2DdnsResponse ([/tool fetch url=("https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=" . $ddns2User . "&p=" . $ddns2Hash) output=user as-value]->"data")
    } on-error={
        :log error "ERROR DDNS WAN2: No se pudo consultar cdmon"
    }
    
    # Parsear respuesta: buscar "newip=XXXX&..."
    :local wan2RegisteredIP ""
    :if ([:len $wan2DdnsResponse] > 0) do={
        :local s ([:find $wan2DdnsResponse "newip="] + 6)
        :set wan2RegisteredIP [:pick $wan2DdnsResponse $s [:find $wan2DdnsResponse "&" $s]]
    }
    
    # Obtener IP pública actual via ipinfo.io (src-address con IP dinámica de WAN2)
    # NOTA: requiere routing rule que enrute src-address de WAN2 hacia salida_WAN2
    :local wan2CurrentIP ""
    :do {
        :set wan2CurrentIP ([/tool fetch url=$ipinfoUrl src-address=$wan2CurrentLocalIP output=user as-value]->"data")
    } on-error={
        :log error "ERROR DDNS WAN2: No se pudo obtener IP pública de ipinfo.io"
    }
    
    :if ($debugEnabled = true) do={ :log info "WAN2 - IP registrada: $wan2RegisteredIP | IP actual: $wan2CurrentIP" }
    
    # Actualizar DDNS si la IP cambió
    :if ($wan2CurrentIP != "" && $wan2CurrentIP != $wan2RegisteredIP) do={
        :do {
            /tool fetch url=("https://dinamico.cdmon.org/onlineService.php?enctype=MD5&n=" . $ddns2User . "&p=" . $ddns2Hash . "&cip=" . $wan2CurrentIP) keep-result=no
            :if ($debugEnabled = true) do={ :log info "✅ DDNS WAN2 actualizado: $wan2RegisteredIP → $wan2CurrentIP" }
        } on-error={
            :log error "ERROR DDNS WAN2: Fallo al actualizar en cdmon"
        }
    } else={
        :if ($debugEnabled = true) do={ :log info "WAN2 sin cambios de IP, DDNS no actualizado" }
    }
} else={
    :if ($debugEnabled = true) do={ :log info "WAN2 deshabilitado para DDNS (CGNAT) o no está UP" }
}

:if ($debugEnabled = true) do={ :log info "═══════════════════════════════════════════════" }
:if ($debugEnabled = true) do={ :log info ("📊 WAN1 [" . $wan1Status . "] | WAN2 [" . $wan2Status . "]") }
:if ($debugEnabled = true) do={ :log info "═══════════════════════════════════════════════" }
