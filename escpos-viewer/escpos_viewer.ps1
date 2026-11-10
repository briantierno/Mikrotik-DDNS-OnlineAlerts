# Impresora ESC/POS falsa: escucha RAW en :9100 y escribe los tickets en tickets.html (se refresca solo).
# Uso:  powershell -ExecutionPolicy Bypass -File escpos_viewer.ps1 [-Ip 0.0.0.0] [-Port 9100]
param([string]$Ip = "0.0.0.0", [int]$Port = 9100, [string]$Out = "$PSScriptRoot\tickets.html")

try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch {}
$CPS = @{ 0 = 437; 2 = 850; 16 = 1252; 19 = 858 }
$LATIN1 = [Text.Encoding]::GetEncoding(28591)

function Render([byte[]]$d) {
    $st = @{ bold = $false; ul = $false; inv = $false; big = $false; align = 'left'; cp = 850 }
    $tickets = New-Object Collections.Generic.List[string]
    $lines = New-Object Collections.Generic.List[string]
    $cur = New-Object Collections.Generic.List[string]
    $buf = New-Object Collections.Generic.List[byte]
    $n = $d.Length; $i = 0

    function A($k) { if ($i + $k -lt $n) { [int]$d[$i + $k] } else { 0 } }
    function Flush {
        if ($buf.Count -eq 0) { return }
        $t = [Net.WebUtility]::HtmlEncode([Text.Encoding]::GetEncoding($st.cp).GetString($buf.ToArray()))
        $css = @()
        if ($st.bold) { $css += 'font-weight:bold' }
        if ($st.ul) { $css += 'text-decoration:underline' }
        if ($st.inv) { $css += 'background:#000;color:#fff' }
        if ($st.big) { $css += 'font-size:1.8em' }
        if ($css.Count) { $cur.Add("<span style=`"$($css -join ';')`">$t</span>") } else { $cur.Add($t) }
        $buf.Clear()
    }
    function NL {
        $c = if ($cur.Count) { $cur -join '' } else { '&nbsp;' }
        $lines.Add("<div style=`"text-align:$($st.align)`">$c</div>"); $cur.Clear()
    }
    function Cut { if ($cur.Count) { NL }; if ($lines.Count) { $tickets.Add($lines -join ''); $lines.Clear() } }
    function Txt($s) { $cur.Add([Net.WebUtility]::HtmlEncode($s)) }

    while ($i -lt $n) {
        $b = $d[$i]
        if ($b -eq 0x0A) { Flush; NL; $i++ }
        elseif ($b -eq 0x1B) {                                   # ESC
            Flush; $c = A 1
            switch ($c) {
                0x40 { $st.bold = $false; $st.ul = $false; $st.inv = $false; $st.big = $false; $st.align = 'left'; $i += 2 }
                0x21 { $m = A 2; $st.bold = [bool]($m -band 8); $st.big = [bool]($m -band 0x30); $st.ul = [bool]($m -band 0x80); $i += 3 }
                0x45 { $st.bold = [bool]((A 2) -band 1); $i += 3 }
                0x2D { $st.ul = [bool]((A 2) -band 3); $i += 3 }
                0x61 { $st.align = @('left', 'center', 'right')[(A 2) % 48 % 3]; $i += 3 }
                0x64 { for ($k = 0; $k -lt [Math]::Min((A 2), 20); $k++) { NL }; $i += 3 }
                0x74 { $st.cp = if ($CPS.ContainsKey((A 2))) { $CPS[(A 2)] } else { 850 }; $i += 3 }
                0x70 { $i += 5 }                                 # cajon
                0x2A { $w = (A 3) + (A 4) * 256; $i += 5 + $w * $(if ((A 2) -ge 32) { 3 } else { 1 }); Txt '[imagen]' }
                0x32 { $i += 2 }
                0x3C { $i += 2 }
                default { $i += 3 }
            }
        }
        elseif ($b -eq 0x1D) {                                   # GS
            Flush; $c = A 1
            switch ($c) {
                0x21 { $st.big = [bool](A 2); $i += 3 }
                0x42 { $st.inv = [bool]((A 2) -band 1); $i += 3 }
                0x56 { $i += $(if (@(65, 66, 97, 98) -contains (A 2)) { 4 } else { 3 }); Cut }
                0x76 { $w = (A 4) + (A 5) * 256; $h = (A 6) + (A 7) * 256; $i += 8 + $w * $h; Txt '[imagen]'; NL }
                0x28 {
                    $L = (A 3) + (A 4) * 256
                    if ((A 2) -eq 0x6B -and $L -gt 3 -and (A 6) -eq 80 -and $i + 5 + $L -le $n) {
                        Txt "[QR: $($LATIN1.GetString($d, $i + 8, $L - 3))]"; NL
                    }
                    $i += 5 + $L
                }
                0x6B {                                           # codigo de barras
                    $m = A 2
                    if ($m -le 6) {
                        $j = [Array]::IndexOf($d, [byte]0, [Math]::Min($i + 3, $n)); if ($j -lt 0) { $j = $n }
                        $s = $LATIN1.GetString($d, $i + 3, [Math]::Max(0, $j - $i - 3)); $i = $j + 1
                    } else {
                        $L = [Math]::Min((A 3), [Math]::Max(0, $n - $i - 4))
                        $s = $LATIN1.GetString($d, [Math]::Min($i + 4, $n), $L); $i += 4 + (A 3)
                    }
                    Txt "[barras: $s]"; NL
                }
                0x4C { $i += 4 }
                0x57 { $i += 4 }
                default { $i += 3 }
            }
        }
        elseif ($b -eq 0x1C) { $i += $(if ((A 1) -eq 0x70) { 4 } else { 2 }) }   # FS
        elseif ($b -eq 0x10) { $i += $(if ((A 1) -eq 0x04) { 3 } else { 5 }) }   # DLE
        elseif ($b -eq 0x0D -or $b -eq 0x00 -or $b -eq 0x0C) { $i++ }
        else { $buf.Add($b); $i++ }
    }
    Flush; Cut
    return , $tickets.ToArray()
}

$all = New-Object Collections.Generic.List[string]
function Save {
    $html = "<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=2><title>ESC/POS</title>" +
    "<style>body{background:#ddd;font-family:sans-serif;margin:0;padding:16px}" +
    ".t{background:#fff;width:48ch;margin:0 auto 24px;padding:12px;font:13px/1.3 monospace;white-space:pre-wrap;box-shadow:0 2px 6px #0004}" +
    ".h{width:48ch;margin:0 auto;font-size:12px;color:#555}</style>" +
    "<div class=h>$($all.Count) ticket(s) - se borran al reiniciar el script</div><br>" + ($all -join '')
    [IO.File]::WriteAllText($Out, $html, (New-Object Text.UTF8Encoding $false))
}

Save
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($Ip), $Port)
$l.Start()
Write-Host "Impresora RAW en ${Ip}:$Port  ->  tickets en $Out  (Ctrl+C para salir)"
Start-Process $Out
try {
    while ($true) {
        if (-not $l.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $s.ReadTimeout = 2000   # 2 s sin datos = fin del trabajo
        $ms = New-Object IO.MemoryStream; $rb = New-Object byte[] 65536
        try {
            while (($r = $s.Read($rb, 0, $rb.Length)) -gt 0) {
                $ms.Write($rb, 0, $r)
                if ($r -le 8) { for ($k = 0; $k -lt $r - 1; $k++) { if ($rb[$k] -eq 0x10 -and $rb[$k + 1] -eq 4) { $s.WriteByte(0x12); break } } }  # estado -> online
            }
        } catch {}
        $from = $c.Client.RemoteEndPoint.Address; $c.Close()
        $data = $ms.ToArray(); if ($data.Length -eq 0) { continue }
        $t = Get-Date -Format HH:mm:ss
        foreach ($tk in (Render $data)) { $all.Insert(0, "<div class=h>$t - $from - $($data.Length) bytes</div><div class=t>$tk</div>") }
        while ($all.Count -gt 100) { $all.RemoveAt($all.Count - 1) }
        Save
        Write-Host "[$t] ${from}: $($data.Length) bytes"
    }
} finally { $l.Stop() }
