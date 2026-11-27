
#!/usr/bin/env bash

# ============================================================
# BoomProxy VDS Installer
# Ubuntu 22.04 / 24.04
# Nebula Mesh Client
# ============================================================

VERSION="1.0.0"

API="https://2.26.81.157:17443"
LIGHTHOUSE_IP="10.24.0.1"
LIGHTHOUSE_PUBLIC="2.26.81.157:4242"
NEBULA_VERSION="1.12.0"

INSTALL_DIR="/etc/nebula"
BIN_DIR="/usr/local/bin"
SERVICE_NAME="boomproxy-nebula"

TMP_DIR="/tmp/boomproxy-installer"

# ------------------------------------------------------------
# COLORS
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${RESET} $1"
}

success() {
    echo -e "${GREEN}[OK]${RESET} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${RESET} $1"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

fail() {
    error "$1"
    exit 1
}

banner() {
    clear 2>/dev/null || true

    echo -e "${CYAN}"
    echo "  ____                              ____                       "
    echo " | __ )  ___   ___  _ __ ___  _ __  |  _ \ _ __ _____  ___   _ "
    echo " |  _ \ / _ \ / _ \| '_ \` _ \| '_ \ | |_) | '__/ _ \ \/ / | | |"
    echo " | |_) | (_) | (_) | | | | | | |_) ||  __/| | | (_) >  <| |_| |"
    echo " |____/ \___/ \___/|_| |_| |_| .__/ |_|   |_|  \___/_/\_\\\\__, |"
    echo "                             |_|                          |___/"
    echo
    echo "                 VDS INSTALLER"
    echo "                 Version ${VERSION}"
    echo -e "${RESET}"
    echo "============================================================"
    echo
}

# ------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    fail "Запусти установщик от root."
fi

banner

# ------------------------------------------------------------
# OS CHECK
# ------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    fail "Не удалось определить операционную систему."
fi

. /etc/os-release

if [ "${ID:-}" != "ubuntu" ]; then
    fail "Поддерживается Ubuntu 22.04 и Ubuntu 24.04."
fi

case "${VERSION_ID:-}" in
    22.04|24.04)
        success "Обнаружена Ubuntu ${VERSION_ID}"
        ;;
    *)
        fail "Версия Ubuntu ${VERSION_ID:-unknown} не поддерживается."
        ;;
esac

# ------------------------------------------------------------
# ARCHITECTURE
# ------------------------------------------------------------

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        NEBULA_ARCH="amd64"
        ;;
    aarch64|arm64)
        NEBULA_ARCH="arm64"
        ;;
    *)
        fail "Архитектура ${ARCH} не поддерживается."
        ;;
esac

success "Архитектура: ${NEBULA_ARCH}"

# ------------------------------------------------------------
# PACKAGES
# ------------------------------------------------------------

info "Установка необходимых пакетов..."

apt-get update || fail "Ошибка apt update"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    iproute2 \
    python3 \
    tar \
    gzip \
    systemd \
    || fail "Не удалось установить зависимости."

success "Зависимости установлены."

# ------------------------------------------------------------
# DIRECTORIES
# ------------------------------------------------------------

mkdir -p "$INSTALL_DIR"
mkdir -p "$TMP_DIR"

chmod 700 "$INSTALL_DIR"

# ------------------------------------------------------------
# NEBULA INSTALLATION
# ------------------------------------------------------------

info "Загрузка Nebula ${NEBULA_VERSION}..."

ARCHIVE="nebula-linux-${NEBULA_ARCH}.tar.gz"

DOWNLOAD_URL="https://github.com/slackhq/nebula/releases/download/v${NEBULA_VERSION}/${ARCHIVE}"

curl -fL --retry 3 "$DOWNLOAD_URL" \
    -o "${TMP_DIR}/${ARCHIVE}" \
    || fail "Не удалось скачать Nebula."

info "Распаковка Nebula..."

tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$TMP_DIR" \
    || fail "Ошибка распаковки Nebula."

NEBULA_BIN="$(find "$TMP_DIR" -type f -name nebula | head -n 1)"
CERT_BIN="$(find "$TMP_DIR" -type f -name nebula-cert | head -n 1)"

[ -n "$NEBULA_BIN" ] || fail "Бинарный файл nebula не найден."
[ -n "$CERT_BIN" ] || fail "Бинарный файл nebula-cert не найден."

install -m 755 "$NEBULA_BIN" "${BIN_DIR}/nebula"
install -m 755 "$CERT_BIN" "${BIN_DIR}/nebula-cert"

success "Nebula установлена."

# ------------------------------------------------------------
# HOST KEY GENERATION
# ------------------------------------------------------------

info "Подготовка ключей сервера..."

if [ -f "${INSTALL_DIR}/host.key" ]; then
    warning "Найден существующий host.key. Существующий ключ сохраняется."

    if [ ! -f "${INSTALL_DIR}/host.pub" ]; then
        fail "Найден host.key, но отсутствует host.pub. Не перезаписываю ключ."
    fi
else
    umask 077

    "${BIN_DIR}/nebula-cert" keygen \
        -out-key "${INSTALL_DIR}/host.key" \
        -out-pub "${INSTALL_DIR}/host.pub" \
        || fail "Не удалось создать ключи Nebula."
fi

chmod 600 "${INSTALL_DIR}/host.key"
chmod 644 "${INSTALL_DIR}/host.pub"

success "Ключи готовы."

# ------------------------------------------------------------
# BOOMPROXY REGISTRATION
# ------------------------------------------------------------

info "Регистрация VDS в BoomProxy..."
echo
echo "Токен должен быть создан в административной панели BoomProxy."
echo "Он не сохраняется в установщике или GitHub."
echo

# ------------------------------------------------------------
# API REQUEST
# ------------------------------------------------------------

python3 - <<'PY'
import os
import sys
import json
import ssl
import getpass
import urllib.request
import urllib.error
import ipaddress
import re

api = "https://2.26.81.157:17443/api/servers/enroll"
directory = "/etc/nebula"

print("Введите токен регистрации BoomProxy.")
token = getpass.getpass("Registration token: ").strip()

if len(token) < 32:
    print("ОШИБКА: токен слишком короткий.")
    sys.exit(1)

try:
    with open(directory + "/host.pub", "r") as f:
        public_key = f.read().strip()
except Exception as e:
    print("Не удалось прочитать публичный ключ:", e)
    sys.exit(1)

payload = json.dumps({
    "token": token,
    "publicKey": public_key
}).encode("utf-8")

request = urllib.request.Request(
    api,
    data=payload,
    headers={
        "Content-Type": "application/json",
        "Accept": "application/json"
    },
    method="POST"
)

# API currently uses an IP-based HTTPS endpoint.
# Certificate verification is disabled for compatibility
# with the existing registration workflow.
context = ssl._create_unverified_context()

try:
    with urllib.request.urlopen(
        request,
        context=context,
        timeout=30
    ) as response:
        result = json.loads(response.read().decode("utf-8"))

except urllib.error.HTTPError as e:
    print("Ошибка регистрации HTTP:", e.code)
    try:
        print(e.read().decode("utf-8"))
    except Exception:
        pass
    sys.exit(1)

except Exception as e:
    print("Ошибка подключения к BoomProxy:", str(e))
    sys.exit(1)

if result.get("status") != "approved":
    print("Сервер не одобрен.")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(1)

server_id = result.get("serverId")
virtual_ips = result.get("virtualIps")
groups = result.get("groups")
certificate = result.get("nebulaCertificate")
ca_certificate = result.get("caCertificate")

if not server_id or not isinstance(virtual_ips, list) or not virtual_ips:
    print("Некорректный ответ API: отсутствует Server ID или IP.")
    sys.exit(1)

if not isinstance(groups, list) or not groups:
    print("Некорректный ответ API: отсутствуют сетевые группы.")
    sys.exit(1)

if not certificate or not ca_certificate:
    print("API не вернул сертификаты.")
    sys.exit(1)

if not re.fullmatch(r"BPS-[A-F0-9]{16}", server_id):
    print("Некорректный Server ID.")
    sys.exit(1)

for group in groups:
    if not isinstance(group, str) or not re.fullmatch(r"bp_[a-f0-9]{12}", group):
        print("Некорректная сетевая группа:", group)
        sys.exit(1)

for address in virtual_ips:
    try:
        ip = ipaddress.ip_address(address)
        if ip.version != 4 or ip not in ipaddress.ip_network("10.24.0.0/16"):
            raise ValueError()
        if address in ("10.24.0.1", "10.24.0.4"):
            raise ValueError()
    except Exception:
        print("Некорректный виртуальный IP:", address)
        sys.exit(1)

with open(directory + "/host.crt", "w") as f:
    f.write(certificate.rstrip() + "\n")

with open(directory + "/ca.crt", "w") as f:
    f.write(ca_certificate.rstrip() + "\n")

os.chmod(directory + "/host.crt", 600)
os.chmod(directory + "/ca.crt", 644)

# Build Nebula configuration using the groups returned
# by the BoomProxy registration API.

config = """pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "10.24.0.1": ["2.26.81.157:4242"]

lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    - "10.24.0.1"

listen:
  host: 0.0.0.0
  port: 4242

punchy:
  punch: true
  respond: true

tun:
  dev: nebula0
  drop_local_broadcast: false
  drop_multicast: false
  mtu: 1300

logging:
  level: info
  format: text

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m

  outbound:
    - port: any
      proto: any
      host: any

  inbound:
    - port: any
      proto: any
      groups:
"""

for group in groups:
    config += "        - " + group + "\n"

with open(directory + "/config.yml", "w") as f:
    f.write(config)

os.chmod(directory + "/config.yml", 600)

print()
print("==========================================")
print(" BOOMPROXY REGISTRATION SUCCESSFUL")
print("==========================================")
print("Server ID:", server_id)
print("Virtual IPs:", ", ".join(virtual_ips))
print("Groups:", ", ".join(groups))
print("Certificate:", directory + "/host.crt")
print("CA:", directory + "/ca.crt")
print("==========================================")

PY

if [ "$?" -ne 0 ]; then
    fail "Регистрация BoomProxy не завершилась успешно."
fi

# ------------------------------------------------------------
# SYSTEMD SERVICE
# ------------------------------------------------------------

info "Создание systemd службы..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<'EOF'
[Unit]
Description=BoomProxy Nebula Mesh Client
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nebula -config /etc/nebula/config.yml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || fail "Ошибка systemd daemon-reload"

# ------------------------------------------------------------
# CONFIG VALIDATION
# ------------------------------------------------------------

info "Проверка конфигурации Nebula..."

"${BIN_DIR}/nebula" \
    -config "${INSTALL_DIR}/config.yml" \
    -test

if [ "$?" -ne 0 ]; then
    fail "Конфигурация Nebula не прошла проверку."
fi

success "Конфигурация проверена."

# ------------------------------------------------------------
# START SERVICE
# ------------------------------------------------------------

info "Запуск BoomProxy Mesh..."

systemctl enable "${SERVICE_NAME}" \
    || fail "Не удалось включить автозапуск."

systemctl restart "${SERVICE_NAME}" \
    || fail "Не удалось запустить Nebula."

sleep 3

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 40 --no-pager
    fail "Служба BoomProxy не запустилась."
fi

success "BoomProxy Nebula запущена."

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------

rm -rf "$TMP_DIR"

# ------------------------------------------------------------
# FINAL STATUS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "              BOOMPROXY INSTALLATION COMPLETE"
echo "============================================================"

echo
echo "SERVICE:"
systemctl is-active "${SERVICE_NAME}"

echo
echo "NEBULA INTERFACE:"
ip -brief address show nebula0

echo
echo "ROUTE TO LIGHTHOUSE:"
ip route get 10.24.0.1

echo
echo "SERVICE AUTOSTART:"
systemctl is-enabled "${SERVICE_NAME}"

echo
echo "============================================================"
echo " VDS успешно подключён к BoomProxy Mesh."
echo "============================================================"

echo
echo "Полезные команды:"
echo
echo "Статус:"
echo "systemctl status boomproxy-nebula"
echo
echo "Логи:"
echo "journalctl -u boomproxy-nebula -f"
echo
echo "Перезапуск:"
echo "systemctl restart boomproxy-nebula"
echo
echo "Проверка интерфейса:"
echo "ip -brief address show nebula0"
echo
echo "Проверка Lighthouse:"
echo "ping -c 4 10.24.0.1"
echo
