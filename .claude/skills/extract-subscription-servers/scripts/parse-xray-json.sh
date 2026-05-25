#!/bin/bash
# parse-xray-json.sh — разобрать Xray-JSON (или sing-box JSON) подписку в
# НОРМАЛИЗОВАННЫЙ JSON-массив серверов.
#
# ЗАЧЕМ: современные провайдеры на панели Remnawave (Panterra/NurVPN) отдают
# подписку НЕ списком vless://-ссылок, а массивом полноценных Xray-профилей —
# каждый объект имеет ключи dns/inbounds/outbounds/remarks/routing. Старый
# parse-vless-link.sh такого не понимает (он ждёт vless://-строки), отсюда был
# ложный «0 серверов». Этот скрипт извлекает сервера из .outbounds[].
#
# Поддерживаемые формы входа:
#   1. Xray-JSON массив профилей: [ {remarks, outbounds:[...], ...}, ... ]
#      Сервера — в .outbounds[] | select(.protocol=="vless").
#      ВАЖНО: первый профиль может нести НЕСКОЛЬКО vless-outbounds (группа
#      серверов одной страны под балансир, теги proxy/proxy-2/...) — каждый
#      разворачивается в отдельный сервер. Остальные профили — по одному.
#   2. Xray-JSON одиночный объект: { outbounds:[...], remarks:"..." }.
#   3. sing-box JSON: { outbounds:[ {type:"vless", server, server_port, ...} ] }.
#
# Страна берётся из .remarks профиля (эмодзи-флаг или текст). НЕ выдумываем —
# если не распознали → "?". Логика разбора флага идентична
# save-subscription-servers.sh (единый стиль).
#
# Использование:
#   ./parse-xray-json.sh /path/to/config.json
#   cat config.json | ./parse-xray-json.sh
#
# Выход (stdout): JSON-массив нормализованных серверов. Поля каждого:
#   tag, country, host, port, uuid, flow, network, security,
#   sni, pbk, sid, spx, fp, path, host_header, service_name, alpn
#
# Возвращаемый код:
#   0 — успех (хотя бы один vless-сервер)
#   1 — не Xray/sing-box JSON, или 0 серверов
#   2 — ошибка параметров

set -euo pipefail

# Вход: файл-аргумент или stdin
if [ "$#" -ge 1 ]; then
    [ -f "$1" ] || { echo "ERROR: файл не найден: $1" >&2; exit 2; }
    INPUT="$(cat "$1")"
else
    INPUT="$(cat)"
fi

if [ -z "$INPUT" ]; then
    echo "ERROR: пустой вход" >&2
    exit 2
fi

# Валидируем, что это вообще JSON.
if ! echo "$INPUT" | jq empty >/dev/null 2>&1; then
    echo "ERROR: вход не является валидным JSON (возможно, это base64/plain vless — используй parse-subscription.sh)" >&2
    exit 1
fi

# --- jq-программа нормализации ----------------------------------------------
# Определяем форму и сводим к единому массиву нормализованных серверов.
#
# def flag_to_iso / text_to_iso — определение страны из remarks (как в
# save-subscription-servers.sh, чтобы разметка совпадала во всём проекте).
#
# def norm_xray_outbound($remarks) — один vless-outbound Xray → нормализованный
# объект. Достаёт vnext/streamSettings по точным полям из живого конфига Panterra.
#
# def norm_singbox_outbound — один vless-outbound sing-box → нормализованный объект.
NORMALIZED="$(echo "$INPUT" | jq -c '
    def flag_to_iso($s):
        [ ($s // "") | explode[] | select(. >= 127462 and . <= 127487) | (. - 127397) ]
        | if length >= 2 then ([.[0], .[1]] | implode) else "" end;
    def text_to_iso($s):
        (($s // "") | ascii_upcase) as $t
        | if   ($t | test("\\b(USA|UNITED STATES|US|США|СОЕДИНЁ)\\b")) then "US"
          elif ($t | test("\\b(NETHERLANDS|HOLLAND|NL|НИДЕРЛАНД|ГОЛЛАНД)\\b")) then "NL"
          elif ($t | test("\\b(GERMANY|DEUTSCHLAND|DE|ГЕРМАНИ)\\b")) then "DE"
          elif ($t | test("\\b(FINLAND|FI|ФИНЛЯНД)\\b")) then "FI"
          elif ($t | test("\\b(FRANCE|FR|ФРАНЦ)\\b")) then "FR"
          elif ($t | test("\\b(UNITED KINGDOM|UK|GB|БРИТАН|АНГЛИ)\\b")) then "GB"
          elif ($t | test("\\b(SWEDEN|SE|ШВЕЦИ)\\b")) then "SE"
          elif ($t | test("\\b(JAPAN|JP|ЯПОНИ)\\b")) then "JP"
          elif ($t | test("\\b(SINGAPORE|SG|СИНГАПУР)\\b")) then "SG"
          elif ($t | test("\\b(TURKEY|TR|ТУРЦИ)\\b")) then "TR"
          elif ($t | test("\\b(POLAND|PL|ПОЛЬШ)\\b")) then "PL"
          elif ($t | test("\\b(LATVIA|LV|ЛАТВИ)\\b")) then "LV"
          elif ($t | test("\\b(KAZAKHSTAN|KZ|КАЗАХ)\\b")) then "KZ"
          elif ($t | test("\\b(RUSSIA|RU|РОССИ)\\b")) then "RU"
          else "" end;
    def country_of($remarks):
        (flag_to_iso($remarks)) as $byflag
        | (if $byflag != "" then $byflag else text_to_iso($remarks) end) as $iso
        | if $iso != "" then $iso else "?" end;

    def norm_xray_outbound($remarks):
        . as $ob
        | (.settings.vnext[0] // {}) as $vn
        | (.streamSettings // {}) as $ss
        | (.realitySettings // $ss.realitySettings // {}) as $reality
        | ($ss.tlsSettings // {}) as $tls
        | ($ss.xhttpSettings // {}) as $xhttp
        | ($ss.grpcSettings // {}) as $grpc
        | ($ss.wsSettings // {}) as $ws
        | ($ss.security // "none") as $sec
        | ($ss.network // "tcp") as $net
        # SNI: reality.serverName → tls.serverName → xhttp/ws host → ""
        | (if   $sec == "reality" then ($reality.serverName // "")
           elif $sec == "tls"     then ($tls.serverName // "")
           else "" end) as $sni
        # path: xhttp.path / ws.path
        | (if   $net == "xhttp" then ($xhttp.path // "")
           elif $net == "ws"    then ($ws.path // "")
           else "" end) as $path
        # host header: xhttp.host / ws.headers.Host
        | (if   $net == "xhttp" then ($xhttp.host // "")
           elif $net == "ws"    then ($ws.headers.Host // $ws.headers.host // "")
           else "" end) as $hosth
        | {
            tag:          ($ob.tag // "proxy"),
            country:      country_of($remarks),
            remark:       ($remarks // ""),
            host:         ($vn.address // ""),
            port:         ($vn.port // 0),
            uuid:         ($vn.users[0].id // ""),
            flow:         ($vn.users[0].flow // ""),
            network:      $net,
            security:     $sec,
            sni:          $sni,
            pbk:          ($reality.publicKey // ""),
            sid:          ($reality.shortId // ""),
            spx:          ($reality.spiderX // ""),
            fp:           ($reality.fingerprint // $tls.fingerprint // ""),
            path:         $path,
            host_header:  $hosth,
            service_name: ($grpc.serviceName // ""),
            alpn:         (($tls.alpn // []) | join(","))
          };

    def norm_singbox_outbound($remarks):
        . as $ob
        | ($ob.tls // {}) as $tls
        | ($ob.transport // {}) as $tr
        | ($ob.tls.reality // {}) as $reality
        | (if ($ob.tls.enabled // false) then (if $reality.enabled // false then "reality" else "tls" end) else "none" end) as $sec
        | ($tr.type // "tcp") as $net
        | {
            tag:          ($ob.tag // "proxy"),
            country:      country_of($remarks // $ob.tag),
            remark:       ($remarks // $ob.tag // ""),
            host:         ($ob.server // ""),
            port:         ($ob.server_port // 0),
            uuid:         ($ob.uuid // ""),
            flow:         ($ob.flow // ""),
            network:      $net,
            security:     $sec,
            sni:          ($tls.server_name // ""),
            pbk:          ($reality.public_key // ""),
            sid:          ($reality.short_id // ""),
            spx:          "",
            fp:           ($tls.utls.fingerprint // ""),
            path:         ($tr.path // ""),
            host_header:  (($tr.headers.Host // $tr.host) // ""),
            service_name: ($tr.service_name // ""),
            alpn:         (($tls.alpn // []) | join(","))
          };

    # --- Диспетчер форм ---
    # 1. Массив Xray-профилей: каждый элемент имеет .outbounds + .remarks.
    # 2. Одиночный Xray-объект: .outbounds присутствует на верхнем уровне.
    # 3. sing-box: .outbounds[] с .type (а не .protocol).
    if (type == "array") and (.[0] | type) == "object" and (.[0] | has("outbounds")) then
        # Xray массив профилей
        [ .[] as $profile
          | ($profile.remarks // "") as $rem
          | ($profile.outbounds // [])[]
          | select(.protocol == "vless")
          | norm_xray_outbound($rem) ]
    elif (type == "object") and has("outbounds") and ((.outbounds[0] // {}) | has("protocol")) then
        # одиночный Xray-объект
        (.remarks // "") as $rem
        | [ (.outbounds // [])[]
            | select(.protocol == "vless")
            | norm_xray_outbound($rem) ]
    elif (type == "object") and has("outbounds") then
        # sing-box: outbound с type=vless
        [ (.outbounds // [])[]
          | select((.type // "") == "vless")
          | norm_singbox_outbound(null) ]
    else
        []
    end
')"

# Проверяем, что получили непустой массив
COUNT="$(echo "$NORMALIZED" | jq 'length')"
if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: в JSON не найдено ни одного vless-сервера." >&2
    echo "       Это не Xray/sing-box подписка с серверами, либо формат нестандартный." >&2
    echo "       Первые 200 байт входа: $(echo "$INPUT" | head -c 200)" >&2
    exit 1
fi

echo "[parse-xray] Распознано $COUNT vless-серверов из Xray/sing-box JSON." >&2
# Pretty-print финальный массив на stdout
echo "$NORMALIZED" | jq '.'
exit 0
