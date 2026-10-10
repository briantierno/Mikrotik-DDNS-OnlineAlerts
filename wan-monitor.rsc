# ============================================================================
#  WAN MONITOR  v2.0  -  DMZ Sistemas  (https://dmz.ar)
#  Monitoreo dual-WAN con deteccion en 2 etapas, alertas Telegram/WhatsApp
#  y actualizacion DDNS (cdmon). Alerta solo en CAMBIO de estado.
#  WAN2 es opcional: con cfgWan2Mode="none" el bloque se saltea.
#
#  Este script NO tiene zona de configuracion: lee sus valores del script
#  "dmz-vars", que crea el instalador (dmz-engine.rsc) con los datos del sitio.
#  Para usarlo suelto, crea un script "dmz-vars" con los :global de abajo.
#
#  Requiere rutas recursivas ya creadas:
#    /ip route add dst-address=<sonda>/32 gateway=<gw>%<iface> scope=10
#    /ip route add dst-address=0.0.0.0/0 gateway=<sonda> target-scope=11 \
#        distance=1 check-gateway=ping
#  target-scope=11 es critico: con 10 la ruta queda Inactive.
# ============================================================================

# --- Carga de variables del sitio (sobrevive reinicios) ---
:do { /system script run dmz-vars } on-error={
  :log error "[WAN-MONITOR] No se encontro el script dmz-vars. Abortando."
  :error "dmz-vars ausente"
}

:global cfgWmDebug;      :global cfgWmTelegram;  :global cfgWmTgToken
:global cfgWmTgChatId;   :global cfgWmWhatsapp;  :global cfgWmWaPhone
:global cfgWmWaApiKey;   :global cfgWmDdns;      :global cfgWmDdnsDomain
:global cfgWmDdnsUser;   :global cfgWmDdnsHash;  :global cfgWmNotifyIpChange
:global cfgWan1Gw;       :global cfgWan1Probe
:global cfgWan2Mode;     :global cfgWan2Gw;      :global cfgWan2Probe

:local debugEnabled     $cfgWmDebug
:local ddns1Enabled     $cfgWmDdns
:local notifyIpChange   $cfgWmNotifyIpChange
:local telegramEnabled  $cfgWmTelegram
:local telegramToken    $cfgWmTgToken
:local telegramChatId   $cfgWmTgChatId
:local whatsappEnabled  $cfgWmWhatsapp
:local whatsappPhone    $cfgWmWaPhone
:local whatsappApiKey   $cfgWmWaApiKey
:local ddns1Domain      $cfgWmDdnsDomain
:local ddns1User        $cfgWmDdnsUser
:local ddns1Hash        $cfgWmDdnsHash
:local ddnsProvider     "https://dinamico.cdmon.org/onlineService.php"
:local ipinfoUrl        "https://ipinfo.io/ip"

# --- Parametros ---
:local pingCount 3
:local wan1Gw   $cfgWan1Gw
:local wan1Probe $cfgWan1Probe
:local wan2Gw   $cfgWan2Gw
:local wan2Probe $cfgWan2Probe

# --- Estado persistente entre corridas ---
:global wan1LastStatus
:global wan2LastStatus
:if ([:typeof $wan1LastStatus] = "nothing") do={ :set wan1LastStatus "UP" }
:if ([:typeof $wan2LastStatus] = "nothing") do={ :set wan2LastStatus "UP" }

:local DeviceName [/system identity get name]
:local nowDate [/system clock get date]
:local nowTime [/system clock get time]
:if ($debugEnabled = true) do={ :log info "WAN MONITOR: inicio" }

# --- Funcion de envio (Telegram + WhatsApp) ---
:local sendAlert do={
  :if ($tg = true) do={
    :do { /tool fetch url=("https://api.telegram.org/bot" . $tgToken . "/sendMessage?chat_id=" . $tgChat . "&text=" . $text) keep-result=no } on-error={ :log warning "WAN MONITOR: error Telegram" }
  }
  :if ($wa = true) do={
    :do { /tool fetch url=("https://api.textmebot.com/send.php?recipient=" . $waPhone . "&apikey=" . $waKey . "&text=" . $text) keep-result=no } on-error={ :log warning "WAN MONITOR: error WhatsApp" }
  }
}

# --- Chequeo WAN1: gateway, luego sonda ---
:local wan1Status "UP"
:local p 0
:do { :set p [/ping $wan1Gw count=$pingCount] } on-error={ :set p 0 }
:if ($p = 0) do={
  :set wan1Status "LINK_DOWN"
} else={
  :set p 0
  :do { :set p [/ping $wan1Probe count=$pingCount] } on-error={ :set p 0 }
  :if ($p = 0) do={ :set wan1Status "NO_INET" }
}

# --- Chequeo WAN2 (solo si existe) ---
:local wan2Status "UP"
:if ($cfgWan2Mode != "none") do={
:set p 0
:do { :set p [/ping $wan2Gw count=$pingCount] } on-error={ :set p 0 }
:if ($p = 0) do={
  :set wan2Status "LINK_DOWN"
} else={
  :set p 0
  :do { :set p [/ping $wan2Probe count=$pingCount] } on-error={ :set p 0 }
  :if ($p = 0) do={ :set wan2Status "NO_INET" }
}
}
:if ($debugEnabled = true) do={ :log info ("WAN MONITOR: WAN1=" . $wan1Status . " WAN2=" . $wan2Status) }

# --- Alertas WAN1 (solo si cambio el estado) ---
:if ($wan1Status != $wan1LastStatus) do={
  :local msg ""
  :if ($wan1Status = "LINK_DOWN") do={
    :log error "WAN1 ENLACE CAIDO - Sin respuesta del modem ISP1"
    :set msg ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN1%20ENLACE%20CAIDO%0ASin%20respuesta%20del%20modem%20ISP1%20" . $wan1Gw . "%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ($wan1Status = "NO_INET") do={
    :log error "WAN1 SIN INTERNET - Enlace al modem OK, caida externa"
    :set msg ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN1%20SIN%20INTERNET%0APosible%20caida%20ISP1%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ($wan1Status = "UP") do={
    :log warning "WAN1 RECUPERADA"
    :set msg ("%F0%9F%9F%A2%20%5B" . $DeviceName . "%5D%20WAN1%20RECUPERADA%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ([:len $msg] > 0) do={ $sendAlert tg=$telegramEnabled tgToken=$telegramToken tgChat=$telegramChatId wa=$whatsappEnabled waPhone=$whatsappPhone waKey=$whatsappApiKey text=$msg }
  :set wan1LastStatus $wan1Status
}

# --- Alertas WAN2 (solo si cambio el estado) ---
:if (($cfgWan2Mode != "none") and ($wan2Status != $wan2LastStatus)) do={
  :local msg ""
  :if ($wan2Status = "LINK_DOWN") do={
    :log error "WAN2 ENLACE CAIDO - Sin respuesta del modem ISP2"
    :set msg ("%F0%9F%94%B4%20%5B" . $DeviceName . "%5D%20WAN2%20ENLACE%20CAIDO%0ASin%20respuesta%20del%20modem%20ISP2%20" . $wan2Gw . "%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ($wan2Status = "NO_INET") do={
    :log error "WAN2 SIN INTERNET - Enlace al modem OK, caida externa"
    :set msg ("%F0%9F%9F%A0%20%5B" . $DeviceName . "%5D%20WAN2%20SIN%20INTERNET%0APosible%20caida%20ISP2%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ($wan2Status = "UP") do={
    :log warning "WAN2 RECUPERADA"
    :set msg ("%F0%9F%9F%A2%20%5B" . $DeviceName . "%5D%20WAN2%20RECUPERADA%0AHora:%20" . $nowDate . "%20" . $nowTime)
  }
  :if ([:len $msg] > 0) do={ $sendAlert tg=$telegramEnabled tgToken=$telegramToken tgChat=$telegramChatId wa=$whatsappEnabled waPhone=$whatsappPhone waKey=$whatsappApiKey text=$msg }
  :set wan2LastStatus $wan2Status
}

# --- DDNS CDMON (solo con WAN1 UP: con WAN1 UP la ruta por defecto es WAN1) ---
:if (($wan1Status = "UP") and ($ddns1Enabled = true)) do={
  :local wan1PublicIP ""
  :do {
    :set wan1PublicIP ([/tool fetch url=$ipinfoUrl output=user as-value]->"data")
    :local nl [:find $wan1PublicIP "\n"]
    :if ([:typeof $nl] = "num") do={ :set wan1PublicIP [:pick $wan1PublicIP 0 $nl] }
  } on-error={ :log error "WAN MONITOR: error obteniendo IP publica"; :set wan1PublicIP "" }

  :if ([:len $wan1PublicIP] > 0) do={
    :local oldIp ""
    :do {
      :local r ([/tool fetch url=($ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash) output=user as-value]->"data")
      :local s [:find $r "newip="]
      :if ([:typeof $s] = "num") do={
        :set s ($s + 6)
        :local e [:find $r "&" $s]
        :if ([:typeof $e] = "num") do={ :set oldIp [:pick $r $s $e] } else={ :set oldIp [:pick $r $s [:len $r]] }
      }
    } on-error={ :set oldIp "" }

    :if ($wan1PublicIP != $oldIp) do={
      :log warning ("WAN1 CAMBIO IP - Anterior: " . $oldIp . " -> Nueva: " . $wan1PublicIP)
      :do {
        /tool fetch url=($ddnsProvider . "?enctype=MD5&n=" . $ddns1User . "&p=" . $ddns1Hash . "&cip=" . $wan1PublicIP) keep-result=no
        :if ($notifyIpChange = true) do={
          :local msg ("%F0%9F%94%84%20%5B" . $DeviceName . "%5D%20WAN1%20CAMBIO%20IP%0AIP%20Nueva:%20" . $wan1PublicIP . "%0ADominio:%20" . $ddns1Domain)
          $sendAlert tg=$telegramEnabled tgToken=$telegramToken tgChat=$telegramChatId wa=$whatsappEnabled waPhone=$whatsappPhone waKey=$whatsappApiKey text=$msg
        }
      } on-error={ :log error "WAN MONITOR: error actualizando CDMON" }
    }
  }
}
