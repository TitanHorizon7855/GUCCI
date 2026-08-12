#!/bin/bash
# =====================================================================
#  GUCCI Traffic Ratio — ضریب مصرف ترافیک برای 3x-ui
#
#  روی هر کاربر با ست کردن یک «ضریب»، مصرف ثبت‌شده در دیتابیس را
#  چند برابر (یا کسری) می‌کند تا سهمیه‌ی حجمی بر همان اساس کم شود.
#
#  نحوه تعیین ضریب: در فرم ویرایش کاربر، داخل فیلد «Comment» بنویسید:
#      ضریب:2        یا        ratio=2        یا        ratio:0.5
#
#  اجرا: حلقه‌ی بی‌پایان هر RATIO_INTERVAL ثانیه (پیش‌فرض 45)
#  خروجی: داشبورد زنده روی /var/www/ratio/index.html  (nginx path /ratio/)
#
#  بدون تغییر در باینری x-ui — فقط از بیرون روی SQLite کار می‌کند.
# =====================================================================

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
INTERVAL="${RATIO_INTERVAL:-45}"
WWW="${RATIO_WWW:-/var/www/ratio}"
OUT="$WWW/index.html"

mkdir -p "$WWW"

sql() { sqlite3 -cmd ".timeout 5000" "$DB" "$1" 2>/dev/null; }

# جدول مخصوص خودمان — x-ui به جداول اضافی کاری ندارد
sql "CREATE TABLE IF NOT EXISTS traffic_ratio(
       email     TEXT PRIMARY KEY,
       ratio     REAL    NOT NULL DEFAULT 1.0,
       last_up   INTEGER NOT NULL DEFAULT 0,
       last_down INTEGER NOT NULL DEFAULT 0,
       acc_up    INTEGER NOT NULL DEFAULT 0,
       acc_down  INTEGER NOT NULL DEFAULT 0
     );"

log(){ echo "[ratio] $*"; }

# ---------------------------------------------------------------------
# ۱) خواندن ضریب از Comment هر کلاینت (داخل JSON تنظیمات هر اینباند)
#    نشانه‌های قابل قبول:  ضریب:N   ratio:N   ratio=N
# ---------------------------------------------------------------------
sync_ratios() {
    sql "SELECT settings FROM inbounds;" \
      | jq -r '.clients[]? | [(.email//""), (.comment//"")] | @tsv' 2>/dev/null \
      | while IFS="$(printf '\t')" read -r email comment; do
            [ -z "$email" ] && continue
            safe=${email//\'/}
            r=$(printf '%s' "$comment" \
                  | grep -oiE '(ضریب|ratio)[[:space:]]*[:=][[:space:]]*[0-9]+([.][0-9]+)?' \
                  | grep -oE '[0-9]+([.][0-9]+)?' | head -1)
            [ -z "$r" ] && r=1
            # درج اولیه: last_up/last_down از مصرف فعلی پر می‌شود (تا مصرف قبلی ضرب نخورد)
            sql "INSERT INTO traffic_ratio(email, ratio, last_up, last_down)
                 SELECT '$safe', $r,
                        COALESCE((SELECT up   FROM client_traffics WHERE email='$safe'),0),
                        COALESCE((SELECT down FROM client_traffics WHERE email='$safe'),0)
                 WHERE NOT EXISTS (SELECT 1 FROM traffic_ratio WHERE email='$safe');"
            # به‌روزرسانی ضریب
            sql "UPDATE traffic_ratio SET ratio=$r WHERE email='$safe';"
        done
}

# ---------------------------------------------------------------------
# ۲) اعمال ضریب روی مصرف ثبت‌شده (فقط روی دلتای جدید)
#    ریست دستی/خودکار کاربر هم تشخیص داده می‌شود (cur < last)
# ---------------------------------------------------------------------
apply_ratios() {
    sql "SELECT tr.email, ct.up, ct.down, tr.ratio, tr.last_up, tr.last_down
         FROM traffic_ratio tr
         JOIN client_traffics ct ON ct.email = tr.email;" \
      | while IFS='|' read -r email up down ratio last_up last_down; do
            [ -z "$email" ] && continue
            safe=${email//\'/}

            # تشخیص ریست مصرف
            [ "$up"   -lt "$last_up"   ] && last_up=0
            [ "$down" -lt "$last_down" ] && last_down=0
            dup=$((up - last_up))
            ddown=$((down - last_down))

            one=$(awk "BEGIN{print ($ratio==1)?1:0}")
            if [ "$one" = "1" ] || { [ "$dup" -le 0 ] && [ "$ddown" -le 0 ]; }; then
                sql "UPDATE traffic_ratio SET last_up=$up, last_down=$down WHERE email='$safe';"
                continue
            fi

            e_up=$(awk   "BEGIN{printf \"%d\", $dup   * ($ratio - 1)}")
            e_down=$(awk "BEGIN{printf \"%d\", $ddown * ($ratio - 1)}")

            # max(0,...) تا مصرف منفی نشود
            sql "UPDATE client_traffics
                 SET up       = CASE WHEN up + ($e_up)   < 0 THEN 0 ELSE up + ($e_up)   END,
                     down     = CASE WHEN down + ($e_down) < 0 THEN 0 ELSE down + ($e_down) END,
                     all_time = CASE WHEN all_time + ($e_up) + ($e_down) < 0 THEN 0
                                     ELSE all_time + ($e_up) + ($e_down) END
                 WHERE email='$safe';"
            sql "UPDATE traffic_ratio
                 SET last_up  = $up   + ($e_up),
                     last_down= $down + ($e_down),
                     acc_up   = acc_up   + ($e_up),
                     acc_down = acc_down + ($e_down)
                 WHERE email='$safe';"
        done
}

# ---------------------------------------------------------------------
# ۳) رندر داشبورد زنده (HTML خام، بدون وابستگی)
# ---------------------------------------------------------------------
fmt_gb() { awk "BEGIN{b=$1; if(b<1024*1024) printf \"%.0f KB\", b/1024; else if(b<1073741824) printf \"%.1f MB\", b/1048576; else printf \"%.2f GB\", b/1073741824}"; }

render() {
    local now rows=""
    now=$(date '+%Y-%m-%d %H:%M:%S')
    while IFS='|' read -r email ratio up down acc total enable; do
        [ -z "$email" ] && continue
        real=$(( up + down - acc )); [ "$real" -lt 0 ] && real=0
        adj=$(( up + down ))
        badge="⚖️ $ratio"
        st=$([ "$enable" = "1" ] && echo "🟢" || echo "🔴")
        quota="-"; [ "${total:-0}" != "0" ] && [ -n "$total" ] && quota=$(fmt_gb "$total")
        rows="$rows
        <tr>
          <td class=n>$email</td><td class=b>$badge</td><td>$(fmt_gb $real)</td>
          <td class=a>$(fmt_gb $adj)</td><td>$quota</td><td>$st</td>
        </tr>"
    done <<EOF
$(sql "SELECT tr.email, tr.ratio, ct.up, ct.down, tr.acc_up + tr.acc_down, ct.total, ct.enable
       FROM traffic_ratio tr JOIN client_traffics ct ON ct.email=tr.email
       ORDER BY (ct.up + ct.down) DESC, tr.email;")
EOF

    cat > "$OUT" <<HTML
<!DOCTYPE html><html lang="fa" dir="rtl"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>GUCCI ⚖️ ضریب ترافیک</title>
<style>
 body{margin:0;background:#0b0b0f;color:#e8e8f0;font-family:sans-serif;min-height:100vh}
 h1{font-size:20px;text-align:center;padding:26px 10px 6px;color:#d4af37}
 .t{text-align:center;color:#666;font-size:12px;padding-bottom:18px}
 table{margin:0 auto 40px;border-collapse:collapse;width:min(96%,860px);background:#12121a;border-radius:14px;overflow:hidden}
 th,td{padding:11px 12px;text-align:center;font-size:13.5px;border-bottom:1px solid #1e1e2a}
 th{background:#191924;color:#d4af37;font-weight:600}
 td.n{color:#7ec8ff;text-align:right;padding-right:18px}
 td.b{color:#ffd76e}
 td.a{color:#ff9d9d}
 .foot{text-align:center;color:#444;font-size:11px;padding-bottom:30px;direction:ltr}
</style></head><body>
<h1>⚖️ GUCCI — ضریب مصرف ترافیک</h1>
<div class="t">به‌روزرسانی خودکار هر ۳۰ ثانیه • آخرین اجرا: $now</div>
<table>
 <tr><th>کاربر</th><th>ضریب</th><th>مصرف واقعی</th><th>مصرف حساب‌شده</th><th>سهمیه</th><th>وضعیت</th></tr>$rows
</table>
<div class="foot">ضریب از فیلد Comment کاربر خوانده می‌شود — مثال: <b>ضریب:2</b> یا <b>ratio=0.5</b></div>
</body></html>
HTML
}

log "started (db=$DB interval=${INTERVAL}s www=$WWW)"
while true; do
    [ -f "$DB" ] || { sleep 5; continue; }
    sync_ratios
    apply_ratios
    render
    sleep "$INTERVAL"
done
