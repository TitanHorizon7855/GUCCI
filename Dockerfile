# GUCCI (3x-ui / Sanaei edition) — نسخه v3.4.2 + nginx reverse proxy روی Railway
FROM alpine:3.19

# نسخه پنل سنایی — با ARG قابل تغییر است
ARG XUI_VERSION=v3.4.2

RUN apk add --no-cache \
    curl \
    bash \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    gettext \
    openssl \
    jq \
    && ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime

# دانلود و نصب 3x-ui (سنایی)
RUN curl -L https://github.com/MHSanaei/3x-ui/releases/download/${XUI_VERSION}/x-ui-linux-amd64.tar.gz -o /tmp/x-ui.tar.gz \
    && tar -xzf /tmp/x-ui.tar.gz -C /usr/local/ \
    && rm /tmp/x-ui.tar.gz \
    && chmod +x /usr/local/x-ui/x-ui

RUN mkdir -p /etc/x-ui /var/log/x-ui

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
RUN chmod +x /start.sh

# GUCCI Traffic Ratio daemon (ضریب مصرف)
RUN mkdir -p /usr/local/gucci /var/www/ratio
COPY gucci-multiplier.sh /usr/local/gucci/gucci-multiplier.sh
RUN chmod +x /usr/local/gucci/gucci-multiplier.sh

# Railway پورت رو از طریق متغیر $PORT تزریق می‌کند؛ nginx روی پورت 1 گوش می‌دهد
CMD ["/start.sh"]
