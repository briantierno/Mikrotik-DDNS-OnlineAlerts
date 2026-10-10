# ============================================================================
#  DMZ Sistemas - MOTOR DE INSTALACION            dmz-engine.rsc   v1.0
#  Igual para todos los sitios. NO SE EDITA: todo sale de dmz-config.rsc.
#
#  Uso:   /import dmz-config.rsc        (carga variables, no aplica nada)
#         /import dmz-engine.rsc        (valida y aplica)
#
#  1) VALIDA todas las variables. Si algo esta mal, aborta SIN tocar nada.
#  2) APLICA: identidad, LAN, WAN1/WAN2 con failover recursivo, firewall,
#     WiFi, hotspot, WireGuard, port forwarding, leases, DNS, WAN monitor.
#  3) Es idempotente: se puede volver a correr despues de cambiar el config.
#     Todo lo que crea lleva comentario "dmz:..." y se reemplaza al re-correr.
#     La clave privada de WireGuard se conserva entre corridas.
#
#  Para RouterOS 7.x, familia "wireless" (hAP ac, cAP ac).
#  Los equipos ax (/interface wifi) NO estan soportados.
#  OJO: conectarse por un puerto LAN (no por ether de WAN) antes de correrlo.
# ============================================================================

{
:global cfgSiteName;       :global cfgIdentity;       :global cfgTimeZone
:global cfgAdminPassword
:global cfgLanNet;         :global cfgLanDnsUpstream; :global cfgLanLeaseTime
:global cfgWan1Mode;       :global cfgWan1Iface;      :global cfgWan1Ip
:global cfgWan1Gw;         :global cfgWan1Probe
:global cfgWan2Mode;       :global cfgWan2Iface;      :global cfgWan2Ip
:global cfgWan2Gw;         :global cfgWan2Probe
:global cfgWifi;           :global cfgWifiSsid24;     :global cfgWifiSsid5
:global cfgWifiPassword;   :global cfgWifiCountry
:global cfgHotspot;        :global cfgHsNet;          :global cfgHsVlanId
:global cfgHsIface;        :global cfgHsSsid;         :global cfgHsDnsName
:global cfgHsHtmlDir;      :global cfgHsLoginBy;      :global cfgHsTrialUptime
:global cfgHsTrialReset;   :global cfgHsAdminPassword; :global cfgHsWalledGarden
:global cfgWireGuard;      :global cfgWgEndpoint;     :global cfgWgEndpointPort
:global cfgWgKeepalive;    :global cfgWgServerPubKey; :global cfgWgLocalIp
:global cfgWgAllowed;      :global cfgWgRemoteNets
:global cfgWanMonitor;     :global cfgWmDebug;        :global cfgWmNotifyIpChange
:global cfgWmUrl;          :global cfgWmInterval;     :global cfgWmTelegram
:global cfgWmTgToken;      :global cfgWmTgChatId;     :global cfgWmWhatsapp
:global cfgWmWaPhone;      :global cfgWmWaApiKey;     :global cfgWmDdns
:global cfgWmDdnsDomain;   :global cfgWmDdnsUser;     :global cfgWmDdnsHash
:global cfgPortForward;    :global cfgStaticLeases;   :global cfgStaticDns

:if ([:typeof $cfgSiteName] = "nothing") do={
  :put "[DMZ-ENGINE] No hay variables cargadas. Primero: /import dmz-config.rsc"
  :error "dmz-config no cargado"
}

:put "[DMZ-ENGINE] Validando configuracion..."
:log info "[DMZ-ENGINE] Inicio - validando configuracion"

# ----------------------------------------------------------------------------
#  HELPERS
# ----------------------------------------------------------------------------
# Divide $s por el caracter $d. Ignora espacios al inicio de cada elemento.
:local split do={
  :local out [:toarray ""]
  :local cur ""
  :if ([:len $s] > 0) do={
    :for i from=0 to=([:len $s] - 1) do={
      :local c [:pick $s $i]
      :if ($c = $d) do={
        :set ($out->[:len $out]) $cur
        :set cur ""
      } else={
        :if (!(($c = " ") and ([:len $cur] = 0))) do={ :set cur ($cur . $c) }
      }
    }
    :set ($out->[:len $out]) $cur
  }
  :return $out
}

# true si $v es "a.b.c.d/nn"
:local isCidr do={
  :local s [:find $v "/"]
  :if ([:typeof $s] != "num") do={ :return false }
  :if ([:typeof [:toip [:pick $v 0 $s]]] != "ip") do={ :return false }
  :local m [:tonum [:pick $v ($s + 1) [:len $v]]]
  :if ([:typeof $m] != "num") do={ :return false }
  :return (($m >= 1) and ($m <= 32))
}

# true si $v es un puerto 1-65535
:local isPort do={
  :local p [:tonum $v]
  :if ([:typeof $p] != "num") do={ :return false }
  :return (($p >= 1) and ($p <= 65535))
}

# true si $v son exactamente 3 octetos validos ("192.168.88")
:local isNet3 do={
  :if (([:typeof $v] != "str") or ([:len $v] < 5)) do={ :return false }
  :local dots 0
  :for i from=0 to=([:len $v] - 1) do={ :if ([:pick $v $i] = ".") do={ :set dots ($dots + 1) } }
  :if ($dots != 2) do={ :return false }
  :return ([:typeof [:toip ($v . ".1")]] = "ip")
}

# Escapa " \ $ para escribir un string dentro del source de un script.
:local esc do={
  :local o ""
  :if ([:len $s] > 0) do={
    :for i from=0 to=([:len $s] - 1) do={
      :local c [:pick $s $i]
      :if (($c = "\"") or ($c = "\\") or ($c = "\$")) do={ :set o ($o . "\\") }
      :set o ($o . $c)
    }
  }
  :return $o
}

# ----------------------------------------------------------------------------
#  1) VALIDACION  (no modifica nada)
# ----------------------------------------------------------------------------
:local errs [:toarray ""]

# --- Flags: tienen que ser booleanos reales, sin comillas ---
:foreach n in={"cfgWifi";"cfgHotspot";"cfgWireGuard";"cfgWanMonitor";"cfgWmDebug";"cfgWmNotifyIpChange";"cfgWmTelegram";"cfgWmWhatsapp";"cfgWmDdns"} do={
  :local g [:parse (":global " . $n . "; :return \$" . $n)]
  :if ([:typeof [$g]] != "bool") do={ :set ($errs->[:len $errs]) ($n . " debe ser true o false (sin comillas)") }
}

# --- Identidad ---
:if (([:len $cfgSiteName] = 0) or ([:typeof [:find $cfgSiteName " "]] = "num")) do={ :set ($errs->[:len $errs]) "cfgSiteName vacio o con espacios" }
:if ([:len $cfgIdentity] = 0) do={ :set ($errs->[:len $errs]) "cfgIdentity vacio" }

# --- LAN ---
:if (![$isNet3 v=$cfgLanNet]) do={ :set ($errs->[:len $errs]) "cfgLanNet debe ser 3 octetos, ej: 192.168.88" }
:if ([:typeof [:toip $cfgLanDnsUpstream]] != "ip") do={ :set ($errs->[:len $errs]) "cfgLanDnsUpstream no es una IP" }

# --- WANs ---
:local wanIfaces [:toarray ""]
:foreach n in={1;2} do={
  :local mode $cfgWan1Mode; :local ifc $cfgWan1Iface; :local ip $cfgWan1Ip; :local gw $cfgWan1Gw; :local probe $cfgWan1Probe
  :if ($n = 2) do={ :set mode $cfgWan2Mode; :set ifc $cfgWan2Iface; :set ip $cfgWan2Ip; :set gw $cfgWan2Gw; :set probe $cfgWan2Probe }
  :local w ("WAN" . $n)
  :if (($mode != "static") and ($mode != "dhcp") and ($mode != "none")) do={
    :set ($errs->[:len $errs]) ("cfgWan" . $n . "Mode debe ser static, dhcp o none")
  }
  :if (($mode = "static") or ($mode = "dhcp")) do={
    :if ([:len [/interface find where name=$ifc]] = 0) do={ :set ($errs->[:len $errs]) ($w . ": la interface " . $ifc . " no existe") }
    :if ([:typeof [:toip $probe]] != "ip") do={ :set ($errs->[:len $errs]) ($w . ": la sonda no es una IP") }
    :if ($probe = $cfgLanDnsUpstream) do={ :set ($errs->[:len $errs]) ($w . ": la sonda no puede ser igual a cfgLanDnsUpstream (queda clavada a una sola WAN)") }
    :set ($wanIfaces->[:len $wanIfaces]) $ifc
  }
  :if ($mode = "static") do={
    :if (![$isCidr v=$ip]) do={ :set ($errs->[:len $errs]) ($w . ": IP invalida, formato a.b.c.d/nn") }
    :if ([:typeof [:toip $gw]] != "ip") do={ :set ($errs->[:len $errs]) ($w . ": gateway invalido") }
  }
}
:if (($cfgWan1Mode != "none") and ($cfgWan2Mode != "none")) do={
  :if ($cfgWan1Iface = $cfgWan2Iface) do={ :set ($errs->[:len $errs]) "WAN1 y WAN2 usan la misma interface" }
  :if ($cfgWan1Probe = $cfgWan2Probe) do={ :set ($errs->[:len $errs]) "WAN1 y WAN2 no pueden usar la misma sonda" }
}
:if (($cfgWan1Mode = "none") and ($cfgWan2Mode != "none")) do={ :set ($errs->[:len $errs]) "WAN2 sin WAN1: usar WAN1 como unica salida" }

# --- WiFi ---
:local hasWireless false
:do { :local t [:parse "/interface wireless print count-only"]; :set hasWireless true } on-error={}
:if ($cfgWifi = true) do={
  :if (!$hasWireless) do={ :set ($errs->[:len $errs]) "cfgWifi=true pero el equipo no tiene el paquete wireless (los ax no estan soportados)" }
  :if ([:len $cfgWifiPassword] < 8) do={ :set ($errs->[:len $errs]) "cfgWifiPassword: minimo 8 caracteres" }
  :if ($cfgWifiPassword = "CAMBIAR_CLAVE_WIFI") do={ :set ($errs->[:len $errs]) "cfgWifiPassword sigue con el valor de ejemplo" }
  :if (([:len $cfgWifiSsid24] = 0) or ([:len $cfgWifiSsid5] = 0)) do={ :set ($errs->[:len $errs]) "SSID de WiFi vacio" }
}

# --- Hotspot ---
:if ($cfgHotspot = true) do={
  :if (![$isNet3 v=$cfgHsNet]) do={ :set ($errs->[:len $errs]) "cfgHsNet debe ser 3 octetos" }
  :if ($cfgHsNet = $cfgLanNet) do={ :set ($errs->[:len $errs]) "cfgHsNet no puede ser igual a cfgLanNet" }
  :if (([:typeof $cfgHsVlanId] != "num") or ($cfgHsVlanId < 2) or ($cfgHsVlanId > 4094)) do={ :set ($errs->[:len $errs]) "cfgHsVlanId debe ser un numero entre 2 y 4094" }
  :if ([:len [/interface ethernet find where name=$cfgHsIface]] = 0) do={ :set ($errs->[:len $errs]) ("hotspot: la interface " . $cfgHsIface . " no existe") }
  :foreach i in=$wanIfaces do={ :if ($i = $cfgHsIface) do={ :set ($errs->[:len $errs]) "cfgHsIface no puede ser una WAN" } }
  :if ([:len $cfgHsDnsName] = 0) do={ :set ($errs->[:len $errs]) "cfgHsDnsName vacio" }
  :if (($cfgWifi = true) and ([:len $cfgHsSsid] = 0)) do={ :set ($errs->[:len $errs]) "cfgHsSsid vacio" }
}

# --- WireGuard ---
:if ($cfgWireGuard = true) do={
  :if (([:len $cfgWgServerPubKey] != 44) or ($cfgWgServerPubKey = "PUBLIC_KEY_DEL_SERVIDOR")) do={ :set ($errs->[:len $errs]) "cfgWgServerPubKey invalida (44 caracteres base64)" }
  :if ([:len $cfgWgEndpoint] = 0) do={ :set ($errs->[:len $errs]) "cfgWgEndpoint vacio" }
  :if (![$isPort v=$cfgWgEndpointPort]) do={ :set ($errs->[:len $errs]) "cfgWgEndpointPort invalido" }
  :if (![$isCidr v=$cfgWgLocalIp]) do={ :set ($errs->[:len $errs]) "cfgWgLocalIp invalida (ej: 10.0.0.5/24)" }
  :foreach c in=[$split s=$cfgWgAllowed d=","] do={ :if (![$isCidr v=$c]) do={ :set ($errs->[:len $errs]) ("cfgWgAllowed: " . $c . " no es una red valida") } }
  :foreach c in=[$split s=$cfgWgRemoteNets d=","] do={ :if (![$isCidr v=$c]) do={ :set ($errs->[:len $errs]) ("cfgWgRemoteNets: " . $c . " no es una red valida") } }
}

# --- WAN monitor ---
:if ($cfgWanMonitor = true) do={
  :if ($cfgWan1Mode = "none") do={ :set ($errs->[:len $errs]) "cfgWanMonitor requiere WAN1" }
  :if ([:len $cfgWmUrl] = 0) do={ :set ($errs->[:len $errs]) "cfgWmUrl vacio" }
  :if ([:len $cfgWmInterval] = 0) do={ :set ($errs->[:len $errs]) "cfgWmInterval vacio" }
  :if (($cfgWmTelegram = true) and (([:len $cfgWmTgToken] = 0) or ([:len $cfgWmTgChatId] = 0))) do={ :set ($errs->[:len $errs]) "Telegram activo sin token o chat id" }
  :if (($cfgWmWhatsapp = true) and (([:len $cfgWmWaPhone] = 0) or ([:len $cfgWmWaApiKey] = 0))) do={ :set ($errs->[:len $errs]) "WhatsApp activo sin telefono o api key" }
  :if (($cfgWmDdns = true) and (([:len $cfgWmDdnsUser] = 0) or ([:len $cfgWmDdnsHash] = 0))) do={ :set ($errs->[:len $errs]) "DDNS activo sin usuario o hash" }
}

# --- Port forwarding:  puerto:ip:puertoDestino:protocolo ---
:local pfList [:toarray ""]
:foreach e in=[$split s=$cfgPortForward d=","] do={
  :local f [$split s=$e d=":"]
  :if ([:len $f] != 4) do={
    :set ($errs->[:len $errs]) ("cfgPortForward: '" . $e . "' no tiene formato puerto:ip:puerto:proto")
  } else={
    :if ((![$isPort v=($f->0)]) or (![$isPort v=($f->2)])) do={ :set ($errs->[:len $errs]) ("cfgPortForward: puerto invalido en '" . $e . "'") }
    :if ([:typeof [:toip ($f->1)]] != "ip") do={ :set ($errs->[:len $errs]) ("cfgPortForward: IP invalida en '" . $e . "'") }
    :if ((($f->3) != "tcp") and (($f->3) != "udp")) do={ :set ($errs->[:len $errs]) ("cfgPortForward: protocolo debe ser tcp o udp en '" . $e . "'") }
    :set ($pfList->[:len $pfList]) $f
  }
}

# --- Leases fijos:  mac|ip|comentario ---
:local leaseList [:toarray ""]
:foreach e in=[$split s=$cfgStaticLeases d=","] do={
  :local f [$split s=$e d="|"]
  :if (([:len $f] < 2) or ([:len $f] > 3)) do={
    :set ($errs->[:len $errs]) ("cfgStaticLeases: '" . $e . "' no tiene formato mac|ip|comentario")
  } else={
    :if ([:len ($f->0)] != 17) do={ :set ($errs->[:len $errs]) ("cfgStaticLeases: MAC invalida en '" . $e . "'") }
    :if ([:typeof [:toip ($f->1)]] != "ip") do={ :set ($errs->[:len $errs]) ("cfgStaticLeases: IP invalida en '" . $e . "'") }
    :if ([:len $f] = 2) do={ :set ($f->2) "" }
    :set ($leaseList->[:len $leaseList]) $f
  }
}

# --- DNS estatico:  nombre|ip ---
:local dnsList [:toarray ""]
:foreach e in=[$split s=$cfgStaticDns d=","] do={
  :local f [$split s=$e d="|"]
  :if (([:len $f] != 2) or ([:typeof [:toip ($f->1)]] != "ip")) do={
    :set ($errs->[:len $errs]) ("cfgStaticDns: '" . $e . "' no tiene formato nombre|ip")
  } else={
    :set ($dnsList->[:len $dnsList]) $f
  }
}

:if ([:len $errs] > 0) do={
  :foreach e in=$errs do={ :put ("  ERROR: " . $e); :log error ("[DMZ-ENGINE] " . $e) }
  :put ("[DMZ-ENGINE] " . [:len $errs] . " error(es). No se aplico NADA. Corregir dmz-config.rsc y repetir.")
  :error "validacion fallida"
}
:put "[DMZ-ENGINE] Validacion OK. Aplicando..."

# ----------------------------------------------------------------------------
#  2) IDENTIDAD
# ----------------------------------------------------------------------------
/system identity set name=$cfgIdentity
/system clock set time-zone-autodetect=no time-zone-name=$cfgTimeZone
:do { /system ntp client set enabled=yes servers="time.cloudflare.com,pool.ntp.org" } on-error={ :log warning "[DMZ-ENGINE] No se pudo configurar NTP" }
:if ([:len $cfgAdminPassword] > 0) do={ /user set [find where name="admin"] password=$cfgAdminPassword }

# ----------------------------------------------------------------------------
#  3) LISTAS DE INTERFACES Y BRIDGE
# ----------------------------------------------------------------------------
:foreach l in={"WAN";"LAN"} do={
  :if ([:len [/interface list find where name=$l]] = 0) do={ /interface list add name=$l comment="dmz" }
}

:local br "bridge"
:if ([:len [/interface bridge find where name=$br]] = 0) do={ /interface bridge add name=$br comment="dmz:lan" }
:if ([:len [/interface list member find where list="LAN" and interface=$br]] = 0) do={ /interface list member add list=LAN interface=$br comment="dmz:lan" }

# Todos los ethernet que no son WAN van al bridge
:foreach e in=[/interface ethernet find] do={
  :local en [/interface ethernet get $e name]
  :local isWan false
  :foreach i in=$wanIfaces do={ :if ($i = $en) do={ :set isWan true } }
  :if ((!$isWan) and ([:len [/interface bridge port find where interface=$en]] = 0)) do={
    /interface bridge port add bridge=$br interface=$en comment="dmz:lan"
  }
}

# ----------------------------------------------------------------------------
#  4) LAN:  .1 gateway/DNS, pool .10-.254, DHCP en el bridge
# ----------------------------------------------------------------------------
:local lanGw ($cfgLanNet . ".1")
:local lanAddr ($lanGw . "/24")
:local lanNetwork ($cfgLanNet . ".0/24")

# Primero se agrega la IP nueva y despues se borra la vieja (no corta la sesion)
:if ([:len [/ip address find where address=$lanAddr and interface=$br]] = 0) do={
  /ip address add address=$lanAddr interface=$br comment="dmz:lan"
} else={
  /ip address set [find where address=$lanAddr and interface=$br] comment="dmz:lan"
}
/ip address remove [find where interface=$br and address!=$lanAddr and (comment="defconf" or comment="dmz:lan")]

/ip dns set servers=$cfgLanDnsUpstream allow-remote-requests=yes
:do { /ip dns static set [find where name="router.lan"] address=$lanGw } on-error={}

/ip dhcp-server remove [find where interface=$br and name!="dmz-lan"]
:if ([:len [/ip pool find where name="dmz-lan"]] = 0) do={
  /ip pool add name="dmz-lan" ranges=($cfgLanNet . ".10-" . $cfgLanNet . ".254")
} else={
  /ip pool set [find where name="dmz-lan"] ranges=($cfgLanNet . ".10-" . $cfgLanNet . ".254")
}
/ip pool remove [find where name="default-dhcp"]
:if ([:len [/ip dhcp-server find where name="dmz-lan"]] = 0) do={
  /ip dhcp-server add name="dmz-lan" interface=$br address-pool="dmz-lan" lease-time=$cfgLanLeaseTime disabled=no
} else={
  /ip dhcp-server set [find where name="dmz-lan"] interface=$br address-pool="dmz-lan" lease-time=$cfgLanLeaseTime disabled=no
}
/ip dhcp-server network remove [find where comment="defconf" or comment="dmz:lan" or address=$lanNetwork]
/ip dhcp-server network add address=$lanNetwork gateway=$lanGw dns-server=$lanGw comment="dmz:lan"

# --- Leases fijos ---
/ip dhcp-server lease remove [find where comment~"^dmz:lease"]
:foreach f in=$leaseList do={
  /ip dhcp-server lease add mac-address=($f->0) address=($f->1) server="dmz-lan" comment=("dmz:lease " . ($f->2))
}

# --- DNS estatico ---
/ip dns static remove [find where comment="dmz:dns"]
:foreach f in=$dnsList do={
  /ip dns static add name=($f->0) address=($f->1) comment="dmz:dns"
}

# ----------------------------------------------------------------------------
#  5) WAN1 / WAN2 con failover recursivo
#     sonda/32 via gateway (scope=10) + default via sonda (target-scope=11)
# ----------------------------------------------------------------------------
:if ([:len $wanIfaces] > 0) do={
  # Rutas por defecto estaticas ajenas al motor romperian el failover
  :foreach r in=[/ip route find where dst-address=0.0.0.0/0 and routing-table=main and dynamic=no and !(comment~"^dmz:")] do={
    :log warning ("[DMZ-ENGINE] Se elimina ruta por defecto previa via " . [/ip route get $r gateway])
    /ip route remove $r
  }
}

:foreach n in={1;2} do={
  :local mode $cfgWan1Mode; :local ifc $cfgWan1Iface; :local ip $cfgWan1Ip; :local gw $cfgWan1Gw; :local probe $cfgWan1Probe
  :if ($n = 2) do={ :set mode $cfgWan2Mode; :set ifc $cfgWan2Iface; :set ip $cfgWan2Ip; :set gw $cfgWan2Gw; :set probe $cfgWan2Probe }
  :local tag ("dmz:wan" . $n)

  /ip route remove [find where comment=($tag . "-probe") or comment=($tag . "-default")]

  :if ($mode != "none") do={
    /interface bridge port remove [find where interface=$ifc]
    /interface list member remove [find where interface=$ifc and list="LAN"]
    :if ([:len [/interface list member find where interface=$ifc and list="WAN"]] = 0) do={
      /interface list member add list=WAN interface=$ifc comment=$tag
    }

    :local routeGw ""
    :if ($mode = "static") do={
      /ip dhcp-client remove [find where interface=$ifc]
      /ip address remove [find where comment=$tag]
      /ip address add address=$ip interface=$ifc comment=$tag
      :set routeGw ($gw . "%" . $ifc)
    }
    :if ($mode = "dhcp") do={
      /ip address remove [find where comment=$tag]
      # Al renovar el lease, el script actualiza el gateway de la ruta a la sonda
      :local dscript (":if (\$bound=1) do={ /ip route set [find where comment=\"" . $tag . "-probe\"] gateway=(\$\"gateway-address\" . \"%" . $ifc . "\") }")
      :if ([:len [/ip dhcp-client find where interface=$ifc]] = 0) do={
        /ip dhcp-client add interface=$ifc add-default-route=no use-peer-dns=no use-peer-ntp=no script=$dscript comment=$tag disabled=no
      } else={
        /ip dhcp-client set [find where interface=$ifc] add-default-route=no use-peer-dns=no use-peer-ntp=no script=$dscript comment=$tag disabled=no
      }
      :set routeGw $ifc
      :do {
        :local dc [/ip dhcp-client find where interface=$ifc]
        :if ([/ip dhcp-client get $dc status] = "bound") do={ :set routeGw ([/ip dhcp-client get $dc gateway] . "%" . $ifc) }
      } on-error={}
    }

    /ip route add dst-address=($probe . "/32") gateway=$routeGw scope=10 comment=($tag . "-probe")
    /ip route add dst-address=0.0.0.0/0 gateway=$probe target-scope=11 distance=$n check-gateway=ping comment=($tag . "-default")
    :put ("  WAN" . $n . " (" . $mode . ") en " . $ifc . " - sonda " . $probe)
  } else={
    /ip address remove [find where comment=$tag]
    /ip dhcp-client remove [find where comment=$tag]
    /interface list member remove [find where comment=$tag]
  }
}

# ----------------------------------------------------------------------------
#  6) NAT Y FIREWALL
#     Si el equipo tiene el firewall de fabrica (defconf) se respeta.
#     Si no tiene ninguno, se crea uno equivalente.
# ----------------------------------------------------------------------------
:if ([:len [/ip firewall nat find where action=masquerade and out-interface-list="WAN"]] = 0) do={
  /ip firewall nat add chain=srcnat action=masquerade out-interface-list=WAN comment="dmz:nat"
}

:if ([:len [/ip firewall filter find where comment~"defconf"]] = 0) do={
  /ip firewall filter remove [find where comment~"^dmz:fw"]
  /ip firewall filter add chain=input action=accept connection-state=established,related,untracked comment="dmz:fw aceptar establecidas"
  /ip firewall filter add chain=input action=drop connection-state=invalid comment="dmz:fw descartar invalidas"
  /ip firewall filter add chain=input action=accept protocol=icmp comment="dmz:fw icmp"
  /ip firewall filter add chain=input action=accept dst-address=127.0.0.1 comment="dmz:fw loopback"
  /ip firewall filter add chain=input action=drop in-interface-list=!LAN comment="dmz:fw descartar todo lo que no venga de LAN"
  # Fasttrack saltea el hotspot: solo se usa si no hay hotspot
  :if ($cfgHotspot != true) do={
    /ip firewall filter add chain=forward action=fasttrack-connection connection-state=established,related hw-offload=yes comment="dmz:fw fasttrack"
  }
  /ip firewall filter add chain=forward action=accept connection-state=established,related,untracked comment="dmz:fw aceptar establecidas"
  /ip firewall filter add chain=forward action=drop connection-state=invalid comment="dmz:fw descartar invalidas"
  /ip firewall filter add chain=forward action=drop connection-state=new connection-nat-state=!dstnat in-interface-list=WAN comment="dmz:fw descartar WAN sin dstnat"
} else={
  :if ($cfgHotspot = true) do={
    :do { /ip firewall filter disable [find where action=fasttrack-connection and comment~"defconf"] } on-error={}
  }
}

# --- Port forwarding ---
/ip firewall nat remove [find where comment~"^dmz:pf"]
:foreach f in=$pfList do={
  /ip firewall nat add chain=dstnat action=dst-nat in-interface-list=WAN protocol=($f->3) dst-port=($f->0) to-addresses=($f->1) to-ports=($f->2) comment=("dmz:pf " . ($f->0) . "/" . ($f->3))
}

# ----------------------------------------------------------------------------
#  7) WIFI (paquete wireless)
#     Se ejecuta via :parse para que el motor no falle en equipos sin wireless.
# ----------------------------------------------------------------------------
:if ($cfgWifi = true) do={
  :local ws ""
  :set ws ($ws . ":if ([:len [/interface wireless security-profiles find where name=\"dmz-lan\"]] = 0) do={ /interface wireless security-profiles add name=\"dmz-lan\" }\n")
  :set ws ($ws . "/interface wireless security-profiles set [find where name=\"dmz-lan\"] mode=dynamic-keys authentication-types=wpa2-psk unicast-ciphers=aes-ccm group-ciphers=aes-ccm wpa2-pre-shared-key=\$pass\n")
  :set ws ($ws . ":local w24 [/interface wireless find where default-name~\"wlan\" and band~\"2ghz\"]\n")
  :set ws ($ws . ":local w5 [/interface wireless find where default-name~\"wlan\" and band~\"5ghz\"]\n")
  :set ws ($ws . ":if ([:len \$w24] > 0) do={ /interface wireless set (\$w24->0) mode=ap-bridge band=2ghz-b/g/n channel-width=20/40mhz-XX frequency=auto ssid=\$ssid24 country=\$country installation=indoor wps-mode=disabled security-profile=\"dmz-lan\" disabled=no }\n")
  :set ws ($ws . ":if ([:len \$w5] > 0) do={ /interface wireless set (\$w5->0) mode=ap-bridge band=5ghz-a/n/ac channel-width=20/40/80mhz-XXXX frequency=auto ssid=\$ssid5 country=\$country installation=indoor wps-mode=disabled security-profile=\"dmz-lan\" disabled=no }\n")
  :set ws ($ws . ":foreach w in=(\$w24, \$w5) do={ :local wn [/interface wireless get \$w name]; :if ([:len [/interface bridge port find where interface=\$wn]] = 0) do={ /interface bridge port add bridge=\$br interface=\$wn comment=\"dmz:wifi\" } }\n")
  :set ws ($ws . ":if ((\$hs = true) and ([:len \$w24] > 0)) do={\n")
  :set ws ($ws . "  :if ([:len [/interface wireless security-profiles find where name=\"dmz-hs\"]] = 0) do={ /interface wireless security-profiles add name=\"dmz-hs\" mode=none }\n")
  :set ws ($ws . "  :if ([:len [/interface wireless find where name=\"wlan-hs\"]] = 0) do={ /interface wireless add name=\"wlan-hs\" master-interface=(\$w24->0) mode=ap-bridge }\n")
  :set ws ($ws . "  /interface wireless set [find where name=\"wlan-hs\"] ssid=\$hsSsid security-profile=\"dmz-hs\" disabled=no\n")
  :set ws ($ws . "  :if ([:len [/interface bridge port find where interface=\"wlan-hs\"]] = 0) do={ /interface bridge port add bridge=\$br interface=\"wlan-hs\" comment=\"dmz:hs\" }\n")
  :set ws ($ws . "  /interface bridge port set [find where interface=\"wlan-hs\"] pvid=\$hsVlan\n")
  :set ws ($ws . "} else={\n")
  :set ws ($ws . "  /interface bridge port remove [find where interface=\"wlan-hs\"]\n")
  :set ws ($ws . "  /interface wireless remove [find where name=\"wlan-hs\"]\n")
  :set ws ($ws . "}\n")
  :do {
    :local wf [:parse $ws]
    $wf br=$br pass=$cfgWifiPassword ssid24=$cfgWifiSsid24 ssid5=$cfgWifiSsid5 country=$cfgWifiCountry hs=$cfgHotspot hsSsid=$cfgHsSsid hsVlan=$cfgHsVlanId
    :put "  WiFi configurado"
  } on-error={
    :log error "[DMZ-ENGINE] Error configurando WiFi"
    :put "  ERROR configurando WiFi (ver log)"
  }
}

# ----------------------------------------------------------------------------
#  8) HOTSPOT  (VLAN propia sobre el bridge, aislada de la LAN)
# ----------------------------------------------------------------------------
:local hsIf "vlan-hs"
:if ($cfgHotspot = true) do={
  :local hsGw ($cfgHsNet . ".1")
  :local hsNetwork ($cfgHsNet . ".0/24")

  # VLAN e interfaz L3
  :if ([:len [/interface vlan find where name=$hsIf]] = 0) do={
    /interface vlan add name=$hsIf interface=$br vlan-id=$cfgHsVlanId comment="dmz:hs"
  } else={
    /interface vlan set [find where name=$hsIf] interface=$br vlan-id=$cfgHsVlanId
  }
  :if ([:len [/interface list member find where list="LAN" and interface=$hsIf]] = 0) do={ /interface list member add list=LAN interface=$hsIf comment="dmz:hs" }

  # Puerto cableado del hotspot como acceso (untagged) a la VLAN
  :if ([:len [/interface bridge port find where interface=$cfgHsIface]] = 0) do={ /interface bridge port add bridge=$br interface=$cfgHsIface comment="dmz:hs" }
  /interface bridge port set [find where interface=$cfgHsIface] pvid=$cfgHsVlanId
  /interface bridge vlan remove [find where comment="dmz:hs"]
  /interface bridge vlan add bridge=$br vlan-ids=$cfgHsVlanId tagged=$br comment="dmz:hs"
  /interface bridge set [find where name=$br] vlan-filtering=yes

  # IP, pool y DHCP
  /ip address remove [find where comment="dmz:hs"]
  /ip address add address=($hsGw . "/24") interface=$hsIf comment="dmz:hs"
  :if ([:len [/ip pool find where name="dmz-hs"]] = 0) do={
    /ip pool add name="dmz-hs" ranges=($cfgHsNet . ".10-" . $cfgHsNet . ".254")
  } else={
    /ip pool set [find where name="dmz-hs"] ranges=($cfgHsNet . ".10-" . $cfgHsNet . ".254")
  }
  :if ([:len [/ip dhcp-server find where name="dmz-hs"]] = 0) do={
    /ip dhcp-server add name="dmz-hs" interface=$hsIf address-pool="dmz-hs" lease-time=1h disabled=no
  } else={
    /ip dhcp-server set [find where name="dmz-hs"] interface=$hsIf address-pool="dmz-hs" disabled=no
  }
  /ip dhcp-server network remove [find where comment="dmz:hs" or address=$hsNetwork]
  /ip dhcp-server network add address=$hsNetwork gateway=$hsGw dns-server=$hsGw comment="dmz:hs"

  # Perfil y servidor hotspot
  :if ([:len [/file find where name=$cfgHsHtmlDir]] = 0) do={
    :log warning ("[DMZ-ENGINE] No existe la carpeta " . $cfgHsHtmlDir . ": subir el html del hotspot")
    :put ("  AVISO: no existe la carpeta " . $cfgHsHtmlDir . " (subir el html del hotspot)")
  }
  :if ([:len [/ip hotspot profile find where name="dmz-hs"]] = 0) do={ /ip hotspot profile add name="dmz-hs" }
  /ip hotspot profile set [find where name="dmz-hs"] hotspot-address=$hsGw dns-name=$cfgHsDnsName html-directory=$cfgHsHtmlDir login-by=$cfgHsLoginBy trial-uptime-limit=$cfgHsTrialUptime trial-uptime-reset=$cfgHsTrialReset
  :if ([:len [/ip hotspot find where name="dmz-hs"]] = 0) do={
    /ip hotspot add name="dmz-hs" interface=$hsIf address-pool="dmz-hs" profile="dmz-hs" disabled=no
  } else={
    /ip hotspot set [find where name="dmz-hs"] interface=$hsIf address-pool="dmz-hs" profile="dmz-hs" disabled=no
  }
  /ip hotspot user remove [find where comment="dmz:hs"]
  :if ([:len $cfgHsAdminPassword] > 0) do={
    /ip hotspot user add name="admin" password=$cfgHsAdminPassword server="dmz-hs" comment="dmz:hs"
  }
  /ip hotspot walled-garden remove [find where comment="dmz:hs"]
  :foreach h in=[$split s=$cfgHsWalledGarden d=","] do={
    :if ([:len $h] > 0) do={ /ip hotspot walled-garden add dst-host=$h action=allow comment="dmz:hs" }
  }
  /ip dns static remove [find where comment="dmz:hs"]
  /ip dns static add name=$cfgHsDnsName address=$hsGw comment="dmz:hs"

  # Aislamiento: el hotspot no ve la LAN ni administra el router
  /ip firewall filter remove [find where comment~"^dmz:hs"]
  /ip firewall filter add chain=forward action=drop in-interface=$hsIf out-interface-list=LAN comment="dmz:hs aislar hotspot de la LAN"
  /ip firewall filter add chain=forward action=drop in-interface-list=LAN out-interface=$hsIf connection-state=new comment="dmz:hs aislar LAN del hotspot"
  :local firstRule [/ip firewall filter find where dynamic=no]
  :if ([:len $firstRule] > 0) do={
    /ip firewall filter add chain=input action=drop in-interface=$hsIf protocol=tcp dst-port=21,22,23,8291,8728,8729 comment="dmz:hs sin gestion desde hotspot" place-before=($firstRule->0)
  } else={
    /ip firewall filter add chain=input action=drop in-interface=$hsIf protocol=tcp dst-port=21,22,23,8291,8728,8729 comment="dmz:hs sin gestion desde hotspot"
  }
  :put ("  Hotspot en VLAN " . $cfgHsVlanId . " - " . $hsNetwork)
} else={
  # Hotspot desactivado: se limpia lo que haya creado el motor antes
  :if ([:len [/interface vlan find where name=$hsIf and comment="dmz:hs"]] > 0) do={
    /ip hotspot remove [find where name="dmz-hs"]
    /ip hotspot profile remove [find where name="dmz-hs"]
    /ip hotspot user remove [find where comment="dmz:hs"]
    /ip hotspot walled-garden remove [find where comment="dmz:hs"]
    /ip dhcp-server remove [find where name="dmz-hs"]
    /ip dhcp-server network remove [find where comment="dmz:hs"]
    /ip pool remove [find where name="dmz-hs"]
    /ip address remove [find where comment="dmz:hs"]
    /ip dns static remove [find where comment="dmz:hs"]
    /ip firewall filter remove [find where comment~"^dmz:hs"]
    /interface list member remove [find where comment="dmz:hs"]
    /interface bridge port set [find where interface=$cfgHsIface or interface="wlan-hs"] pvid=1
    /interface bridge port remove [find where comment="dmz:hs" and interface!=$cfgHsIface]
    /interface bridge vlan remove [find where comment="dmz:hs"]
    /interface vlan remove [find where name=$hsIf]
    :put "  Hotspot desactivado y limpiado"
  }
}

# ----------------------------------------------------------------------------
#  9) WIREGUARD hacia el servidor DMZ
#     La interfaz se crea UNA vez: re-correr el motor no cambia la clave.
# ----------------------------------------------------------------------------
:local wgIf "wg-dmz"
:if ($cfgWireGuard = true) do={
  :if ([:len [/interface wireguard find where name=$wgIf]] = 0) do={
    /interface wireguard add name=$wgIf comment="dmz:wg"
  }
  /interface wireguard set [find where name=$wgIf] disabled=no
  /interface wireguard peers remove [find where interface=$wgIf]
  /interface wireguard peers add interface=$wgIf public-key=$cfgWgServerPubKey endpoint-address=$cfgWgEndpoint endpoint-port=$cfgWgEndpointPort allowed-address=$cfgWgAllowed persistent-keepalive=$cfgWgKeepalive comment="dmz:wg"
  /ip address remove [find where comment="dmz:wg"]
  /ip address add address=$cfgWgLocalIp interface=$wgIf comment="dmz:wg"
  /ip route remove [find where comment="dmz:wg"]
  :foreach net in=[$split s=$cfgWgRemoteNets d=","] do={
    /ip route add dst-address=$net gateway=$wgIf comment="dmz:wg"
  }
  :if ([:len [/interface list member find where list="LAN" and interface=$wgIf]] = 0) do={ /interface list member add list=LAN interface=$wgIf comment="dmz:wg" }
  :local pk [/interface wireguard get [find where name=$wgIf] public-key]
  :log warning ("[DMZ-ENGINE] WIREGUARD public-key de " . $cfgSiteName . ": " . $pk)
  :put ("  WireGuard public-key (pegar como peer en el servidor): " . $pk)
} else={
  :if ([:len [/interface wireguard find where name=$wgIf]] > 0) do={
    /interface wireguard set [find where name=$wgIf] disabled=yes
    :put "  WireGuard deshabilitado (la interfaz y su clave se conservan)"
  }
}

# ----------------------------------------------------------------------------
#  10) WAN MONITOR
#      Genera el script "dmz-vars" con los :global que necesita el monitor
#      (sobrevive reinicios) y descarga wan-monitor.rsc del repo.
# ----------------------------------------------------------------------------
:if ($cfgWanMonitor = true) do={
  :local vars {"cfgSiteName";"cfgWan1Mode";"cfgWan1Iface";"cfgWan1Gw";"cfgWan1Probe";"cfgWan2Mode";"cfgWan2Iface";"cfgWan2Gw";"cfgWan2Probe";"cfgWmDebug";"cfgWmNotifyIpChange";"cfgWmTelegram";"cfgWmTgToken";"cfgWmTgChatId";"cfgWmWhatsapp";"cfgWmWaPhone";"cfgWmWaApiKey";"cfgWmDdns";"cfgWmDdnsDomain";"cfgWmDdnsUser";"cfgWmDdnsHash"}
  :local src "# dmz-vars - GENERADO por dmz-engine.rsc. No editar a mano: cambiar dmz-config.rsc y re-correr el motor.\r\n"
  :foreach n in=$vars do={
    :local g [:parse (":global " . $n . "; :return \$" . $n)]
    :local v [$g]
    :local t [:typeof $v]
    :if (($t = "bool") or ($t = "num")) do={
      :set src ($src . ":global " . $n . " " . [:tostr $v] . "\r\n")
    } else={
      :set src ($src . ":global " . $n . " \"" . [$esc s=[:tostr $v]] . "\"\r\n")
    }
  }
  # En DHCP el gateway cambia: se lee del dhcp-client en cada corrida
  :if ($cfgWan1Mode = "dhcp") do={ :set src ($src . ":do { :global cfgWan1Gw [/ip dhcp-client get [find where interface=\"" . $cfgWan1Iface . "\"] gateway] } on-error={}\r\n") }
  :if ($cfgWan2Mode = "dhcp") do={ :set src ($src . ":do { :global cfgWan2Gw [/ip dhcp-client get [find where interface=\"" . $cfgWan2Iface . "\"] gateway] } on-error={}\r\n") }

  :if ([:len [/system script find where name="dmz-vars"]] = 0) do={
    /system script add name="dmz-vars" policy=read,write,test source=$src comment="dmz:wm"
  } else={
    /system script set [find where name="dmz-vars"] policy=read,write,test source=$src
  }

  # Descarga del monitor (la ruta por defecto puede tardar unos segundos)
  :delay 5s
  :local wm ""
  :do { :set wm ([/tool fetch url=$cfgWmUrl output=user as-value]->"data") } on-error={ :set wm "" }
  :if ([:typeof [:find $wm "WAN MONITOR"]] != "num") do={
    :log error ("[DMZ-ENGINE] No se pudo descargar wan-monitor desde " . $cfgWmUrl)
    :put "  ERROR: no se pudo descargar wan-monitor.rsc. Revisar internet y re-correr el motor."
  } else={
    :if ([:len [/system script find where name="wan-monitor"]] = 0) do={
      /system script add name="wan-monitor" policy=read,write,test source=$wm comment="dmz:wm"
    } else={
      /system script set [find where name="wan-monitor"] policy=read,write,test source=$wm
    }
    :if ([:len [/system scheduler find where name="wan-monitor"]] = 0) do={
      /system scheduler add name="wan-monitor" interval=$cfgWmInterval policy=read,write,test on-event="/system script run wan-monitor" comment="dmz:wm"
    } else={
      /system scheduler set [find where name="wan-monitor"] interval=$cfgWmInterval policy=read,write,test on-event="/system script run wan-monitor" disabled=no
    }
    :put ("  WAN monitor instalado (cada " . $cfgWmInterval . ")")
  }
} else={
  :if ([:len [/system scheduler find where name="wan-monitor"]] > 0) do={
    /system scheduler disable [find where name="wan-monitor"]
    :put "  WAN monitor deshabilitado"
  }
}

:log warning ("[DMZ-ENGINE] Configuracion aplicada: " . $cfgSiteName)
:put ("[DMZ-ENGINE] Listo. Sitio " . $cfgSiteName . " (" . $cfgIdentity . ") - LAN " . $lanAddr)
}
