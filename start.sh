#!/bin/bash
set -e

# =====================================================================
#  GUCCI (3x-ui / Sanaei v3.0.2) — nginx reverse proxy روی Railway
#
#  متغیرهای محیطی قابل تنظیم (در Railway → Service → Variables):
#    INBOUND_COUNT     تعداد اینباندهای اضافه /in1..inN   (پیش‌فرض: 50)
#    INBOUND_BASE_PORT پورت پایه اینباندهای اضافه          (پیش‌فرض: 8080)
#    TCP_INBOUND_PORT  پورت اینباند TCP خام برای TCP Proxy (پیش‌فرض: 9090)
#    HOST_ROUTES       مسیریابی دامنه اختصاصی (اختیاری)
#                      مثال: "sub1.example.com:8081,sub2.example.com:8082"
#    RESET_DB          اگر 1 باشد دیتابیس کامل پاک و از صفر ساخته می‌شود
# =====================================================================

INBOUND_COUNT="${INBOUND_COUNT:-50}"
INBOUND_BASE_PORT="${INBOUND_BASE_PORT:-8080}"
TCP_INBOUND_PORT="${TCP_INBOUND_PORT:-9090}"
HOST_ROUTES="${HOST_ROUTES:-}"
RESET_DB="${RESET_DB:-0}"

echo "🚀 Starting 3x-ui (Sanaei) + nginx reverse proxy (GUCCI)..."
echo "   inbound paths  : /in1..in$INBOUND_COUNT -> ports $((INBOUND_BASE_PORT+1))..$((INBOUND_BASE_PORT+INBOUND_COUNT))"
echo "   raw TCP inbound: port $TCP_INBOUND_PORT (Railway TCP Proxy target)"
[ -n "$HOST_ROUTES" ] && echo "   host routes    : $HOST_ROUTES"

# ریست کامل دیتابیس در صورت نیاز
if [ "$RESET_DB" = "1" ]; then
    echo "⚠️  RESET_DB=1 -> wiping x-ui database for a fresh start..."
    rm -f /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-shm /etc/x-ui/x-ui.db-wal
    echo "  ✔ old database removed"
fi

cd /usr/local/x-ui

echo "🔧 Applying panel settings via x-ui CLI (panel internal port = 2053, base path = /gucci/)..."
./x-ui setting -port 2053 -webBasePath /gucci/ || true

DB=/etc/x-ui/x-ui.db

# تنظیم امن یک کلید در جدول settings:
# در دیتابیس تازه این جدول خالی است (UPDATE به تنهایی هیچ ردیفی را تغییر نمی‌دهد)،
# پس اول UPDATE و در صورت نبود ردیف INSERT می‌کنیم.
set_sub_setting() {
    local key="$1" value="$2"
    sqlite3 "$DB" "UPDATE settings SET value='$value' WHERE key='$key';
INSERT INTO settings (key, value) SELECT '$key','$value' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$key');"
    echo "  ✔ sub setting [$key] = $(sqlite3 "$DB" "SELECT value FROM settings WHERE key='$key' LIMIT 1;")"
}

if [ -f "$DB" ]; then
    echo "🔧 Configuring subscription service (internal 127.0.0.1:443, HTTP)..."
    set_sub_setting subEnable     true
    set_sub_setting subJsonEnable false
    set_sub_setting subListen     127.0.0.1
    set_sub_setting subPort       443
    set_sub_setting subPath       /sub/
    set_sub_setting subJsonPath   /json/
    set_sub_setting subClashPath  /clash/

    # مسیرهای cert به‌صورت «نشانگر TLS» ست می‌شوند تا 3x-ui لینک‌ها را با https:// و
    # بدون پورت بسازد:  https://{دامنه‌ی پنل}/sub/...
    # (فایل‌ها وجود ندارند؛ سرویس ساب خودش به HTTP روی 127.0.0.1:443 برمی‌گردد)
    set_sub_setting subCertFile   /etc/x-ui/sub-dummy-cert.pem
    set_sub_setting subKeyFile    /etc/x-ui/sub-dummy-key.pem

    # سه لینک ساب خالی -> لینک داینامیک با همان دامنه‌ای که پنل با آن باز شده
    set_sub_setting subURI        ""
    set_sub_setting subJsonURI    ""
    set_sub_setting subClashURI   ""
else
    echo "⚠️  DB not found at $DB (x-ui will create it) - skipping sub settings"
fi

# ---------------------------------------------------------------------
# 🩹 خودترمیمی: اینباندهایی که security=tls دارند (با گواهی خالی) کل هسته
# Xray را کرش می‌دهند و همه اینباندهای دیگر را هم می‌اندازند. روی Railway
# TLS در لبه terminate می‌شود، پس security آن‌ها به none تبدیل می‌شود.
# (Reality دست‌نخورده می‌ماند.)
# ---------------------------------------------------------------------
if [ -f "$DB" ]; then
    TLSFIX=$(sqlite3 "$DB" "UPDATE inbounds SET stream_settings = json_set(stream_settings, '\$.security', 'none') WHERE json_extract(stream_settings, '\$.security') = 'tls'; SELECT changes();" 2>/dev/null || echo 0)
    [ "${TLSFIX:-0}" != "0" ] && echo "🩹 detached TLS from $TLSFIX inbound(s) -> security=none (Railway edge terminates TLS)"
fi

# ---------------------------------------------------------------------
# 🎛️  GUCCI Traffic Ratio — ضریب مصرف ترافیک کاربران
#
#  نحوه استفاده: در فرم ویرایش کاربر، فیلد Comment → «ضریب:2» یا «ratio=0.5»
#  داشبورد زنده: https://دامنه/ratio/ (ورود با RATIO_USER / RATIO_PASS)
#  متغیرها:
#    RATIO_USER      یوزر داشبورد      (پیش‌فرض: gucci)
#    RATIO_PASS      رمز داشبورد       (پیش‌فرض: gucci — حتماً عوض کن!)
#    RATIO_INTERVAL  بازه اعمال ضریب   (پیش‌فرض: 45 ثانیه)
# ---------------------------------------------------------------------
RATIO_USER="${RATIO_USER:-gucci}"
RATIO_PASS="${RATIO_PASS:-gucci}"
mkdir -p /var/www/ratio
printf '%s:%s\n' "$RATIO_USER" "$(openssl passwd -apr1 "$RATIO_PASS")" > /etc/nginx/.htpasswd_ratio
if [ "$RATIO_PASS" = "gucci" ]; then
    echo "⚠️  RATIO_PASS تنظیم نشده — داشبورد /ratio/ با رمز پیش‌فرض gucci باز می‌شود!"
fi
echo "🎛️  starting traffic-ratio daemon (every ${RATIO_INTERVAL:-45}s, dashboard at /ratio/)..."
nohup /usr/local/gucci/gucci-multiplier.sh >> /var/log/x-ui/ratio.log 2>&1 &

# ---------------------------------------------------------------------
# تولید کانفیگ nginx (داینامیک)
# ---------------------------------------------------------------------
GEN_DIR=$(mktemp -d)

# ۱) لوکیشن‌های اینباند اضافه:  /in{i} -> پورت (BASE+i)
gen_inbound_locations() {
    local i port
    for i in $(seq 1 "$INBOUND_COUNT"); do
        port=$((INBOUND_BASE_PORT + i))
        cat <<EOF
        # اینباند $i -> پورت داخلی $port
        location /in$i {
            proxy_pass http://127.0.0.1:$port;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$real_scheme;
        }

EOF
    done
}

# ۲) سرورهای دامنه اختصاصی: هر دامنه -> پورت اینباند خودش
gen_host_route_servers() {
    [ -z "$HOST_ROUTES" ] && return 0
    local r host port
    IFS=',' read -ra ROUTES <<< "$HOST_ROUTES"
    for r in "${ROUTES[@]}"; do
        r="${r// /}"
        [ -z "$r" ] && continue
        host="${r%%:*}"
        port="${r##*:}"
        case "$port" in (*[!0-9]*|'') echo "  ⚠️  HOST_ROUTES entry '$r' invalid, skipped" >&2; continue;; esac
        cat <<EOF
    # دامنه اختصاصی $host -> پورت داخلی $port
    server {
        listen 1;
        server_name $host;
        absolute_redirect off;

        location / {
            proxy_pass http://127.0.0.1:$port;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$real_scheme;
        }
    }

EOF
        echo "  ✔ host route: $host -> 127.0.0.1:$port" >&2
    done
}

echo "🔧 Generating nginx config ($INBOUND_COUNT inbound paths + host routes)..."
gen_inbound_locations  > "$GEN_DIR/inbounds.conf"
gen_host_route_servers > "$GEN_DIR/hostroutes.conf"

awk -v inc="$GEN_DIR/inbounds.conf" -v hst="$GEN_DIR/hostroutes.conf" '
    /__INBOUND_LOCATIONS__/   { while ((getline line < inc) > 0) print line; close(inc); next }
    /__HOST_ROUTE_SERVERS__/  { while ((getline line < hst) > 0) print line; close(hst); next }
    { print }
' /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

rm -rf "$GEN_DIR"

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!

sleep 3

# ---------------------------------------------------------------------
#  هسته Xray مستقل برای اینباند TCP خام (Reality) — خارج از پنل
# پورت TCP_INBOUND_PORT (پیش‌فرض 9090) را با VLESS+Reality پر می‌کند تا
# TCP Proxy رای‌وی بدون هیچ تنظیمی در پنل، همین الان کار کند.
# کلیدها روی Volume ذخیره می‌شوند -> لینک کلاینت بین دیپلوی‌ها ثابت است.
# ---------------------------------------------------------------------
XRAY_BIN=""
for c in /usr/local/x-ui/bin/xray /usr/local/x-ui/bin/xray-linux-amd64; do
    [ -x "$c" ] && XRAY_BIN="$c" && break
done
ENV_FILE=/etc/x-ui/reality.env
if [ -n "$XRAY_BIN" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        if [ -n "$REALITY_SEED" ]; then
            # کلیدهای قطعی از seed (برای سرویس‌های node بدون Volume)
            echo "🔑 Deriving Reality keys from REALITY_SEED..."
            REALITY_PRIV=$(printf %s "$REALITY_SEED" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
            REALITY_PUB=$("$XRAY_BIN" x25519 -i "$REALITY_PRIV" | awk '/PublicKey/{print $3}')
            H1=$(printf %s "$REALITY_SEED-uuid" | openssl dgst -sha256 | awk '{print $NF}')
            REALITY_UUID="${H1:0:8}-${H1:8:4}-${H1:12:4}-${H1:16:4}-${H1:20:12}"
            REALITY_SID=$(printf %s "$REALITY_SEED-sid" | openssl dgst -sha256 | awk '{print $NF}' | head -c 16)
        else
            echo "🔑 Generating Reality keys (persisted on volume)..."
            KEYS=$("$XRAY_BIN" x25519 || true)
            REALITY_PRIV=$(echo "$KEYS" | awk '/PrivateKey:/{print $2}')
            REALITY_PUB=$(echo "$KEYS" | awk '/PublicKey/{print $3}')
            REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
            REALITY_SID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        fi
        cat > "$ENV_FILE" <<E
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_UUID=$REALITY_UUID
REALITY_SID=$REALITY_SID
E
    fi
    if [ "${REALITY_REGEN:-0}" = "1" ]; then
        echo "⚠️  REALITY_REGEN=1 -> regenerating Reality keys..."
        rm -f "$ENV_FILE"
        KEYS=$("$XRAY_BIN" x25519 || true)
        REALITY_PRIV=$(echo "$KEYS" | awk '/PrivateKey:/{print $2}')
        REALITY_PUB=$(echo "$KEYS" | awk '/PublicKey/{print $3}')
        REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
        REALITY_SID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
        cat > "$ENV_FILE" <<E
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_UUID=$REALITY_UUID
REALITY_SID=$REALITY_SID
E
    fi
    . "$ENV_FILE"

    # بررسی یکپارچگی کلیدها (pub نمایش‌داده‌شده باید با pub مشتق‌شده از priv یکی باشد)
    DERIVED=$("$XRAY_BIN" x25519 -i "$REALITY_PRIV" 2>/dev/null | awk '/PublicKey/{print $3}')
    echo "  key check: pub=$REALITY_PUB derived=$DERIVED priv_len=${#REALITY_PRIV} sid=$REALITY_SID"

    cat > /etc/x-ui/tcp-node.json <<E
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $TCP_INBOUND_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "tag": "gucci-reality",
      "settings": {
        "clients": [ { "id": "$REALITY_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "serverNames": [ "www.microsoft.com" ],
          "privateKey": "$REALITY_PRIV",
          "shortIds": [ "$REALITY_SID" ]
        }
      }
    },
    {
      "port": $((TCP_INBOUND_PORT + 1)),
      "listen": "0.0.0.0",
      "protocol": "vless",
      "tag": "gucci-tcp-plain",
      "settings": {
        "clients": [ { "id": "$REALITY_UUID" } ],
        "decryption": "none"
      }
    },
    {
      "port": $((TCP_INBOUND_PORT + 2)),
      "listen": "0.0.0.0",
      "protocol": "vless",
      "tag": "gucci-tcp-plain2",
      "settings": {
        "clients": [ { "id": "$REALITY_UUID" } ],
        "decryption": "none"
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
E

    echo "▶️  Starting standalone Xray (Reality on port $TCP_INBOUND_PORT)..."
    if "$XRAY_BIN" run -test -c /etc/x-ui/tcp-node.json >/dev/null 2>&1; then
        "$XRAY_BIN" run -c /etc/x-ui/tcp-node.json &
        echo "  ✔ Reality inbound ready"
    else
        echo "  ⚠️  Reality config invalid - sidecar skipped (see /var/log/x-ui/reality.log)"
    fi
    echo "  🔗 client link (use your TCP Proxy host:port):"
    echo "  vless://$REALITY_UUID@__TCP_PROXY_HOST__:__TCP_PROXY_PORT__?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID&type=tcp&headerType=none#GUCCI-Reality"
else
    echo "⚠️  xray binary not found - skipping standalone Reality inbound"
fi

echo "▶️  Pre-flight checks..."
curl -s -o /dev/null -w "  panel (x-ui)     http://127.0.0.1:2053/gucci/ -> HTTP %{http_code}\n" http://127.0.0.1:2053/gucci/ || echo "  panel not ready yet"
curl -s -o /dev/null -w "  sub server       http://127.0.0.1:443/sub/x  -> HTTP %{http_code}\n" "http://127.0.0.1:443/sub/x" || echo "  sub server not ready yet"
echo "  raw TCP inbound  : create it in the panel on port $TCP_INBOUND_PORT (TCP Proxy target)"

echo "▶️  Starting nginx in foreground on port 1..."
nginx -t
exec nginx -g "daemon off;"
