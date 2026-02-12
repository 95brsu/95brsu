#!/usr/bin/env bash
set -Eeuo pipefail

# Fully automated installer for Ubuntu 24.04:
# - Xray (VLESS + REALITY)
# - Shadowsocks-2022 (served by Xray)
# - QR/link generation for clients

SCRIPT_VERSION="1.0.0"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
OUTPUT_DIR="/root/vpn-links"
LOG_FILE="/var/log/ss-v2ray-installer.log"

# Defaults (can be overridden via env variables)
VLESS_PORT="${VLESS_PORT:-443}"
SS_PORT="${SS_PORT:-8388}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"

err() {
  local exit_code=$?
  echo "[ERROR] line=${BASH_LINENO[0]} cmd='${BASH_COMMAND}' exit=${exit_code}" | tee -a "$LOG_FILE" >&2
  exit "$exit_code"
}
trap err ERR

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Запустите скрипт от root: sudo bash $0" >&2
    exit 1
  fi
}

require_ubuntu_24() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Не найден /etc/os-release" >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Поддерживается только Ubuntu. Обнаружено: ${ID:-unknown}" >&2
    exit 1
  fi

  if [[ "${VERSION_ID:-}" != "24.04" && "${VERSION_ID:-}" != "24.0" ]]; then
    echo "Скрипт рассчитан на Ubuntu 24.04. Обнаружено: ${VERSION_ID:-unknown}" >&2
    exit 1
  fi
}

install_dependencies() {
  log "Устанавливаем зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl jq openssl qrencode uuid-runtime ca-certificates
}

install_xray() {
  log "Устанавливаем/обновляем Xray..."
  local install_script="/tmp/install-release.sh"
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$install_script"
  bash "$install_script" install

  if ! command -v xray >/dev/null 2>&1; then
    echo "Xray не установлен или не найден в PATH" >&2
    exit 1
  fi
}

get_public_ip() {
  local ip
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="YOUR_SERVER_IP"
    log "Не удалось автоматически определить внешний IP, используем заглушку: ${ip}"
  fi
  printf '%s' "$ip"
}

generate_values() {
  log "Генерируем ключи и параметры..."

  # VLESS UUID
  VLESS_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  # REALITY X25519 keypair
  local keypair
  keypair="$(xray x25519)"
  REALITY_PRIVATE_KEY="$(
    awk 'BEGIN{IGNORECASE=1} /private/{print; exit}' <<<"$keypair" |
      grep -Eo '[A-Za-z0-9_+/=-]{20,}' |
      head -n1 |
      tr -d '"\r\n'
  )"
  REALITY_PUBLIC_KEY="$(
    awk 'BEGIN{IGNORECASE=1} /public/{print; exit}' <<<"$keypair" |
      grep -Eo '[A-Za-z0-9_+/=-]{20,}' |
      head -n1 |
      tr -d '"\r\n'
  )"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    echo "xray x25519 output:" >&2
    printf '%s\n' "$keypair" >&2
    echo "Ошибка генерации REALITY ключей" >&2
    exit 1
  fi

  # shortId: 8 bytes hex (16 chars)
  REALITY_SHORT_ID="$(openssl rand -hex 8)"

  # Shadowsocks-2022 password for 2022-blake3-aes-128-gcm: exactly 16 bytes base64
  SS_PASSWORD="$(openssl rand -base64 16 | tr -d '\n')"

  PUBLIC_IP="$(get_public_ip)"

  HOST_TAG="${PUBLIC_IP}"
  if [[ "$HOST_TAG" == "YOUR_SERVER_IP" ]]; then
    HOST_TAG="manual-host"
  fi
}

write_xray_config() {
  log "Пишем конфигурацию Xray..."
  install -d -m 750 /usr/local/etc/xray

  jq -n \
    --arg vless_uuid "$VLESS_UUID" \
    --arg reality_private_key "$REALITY_PRIVATE_KEY" \
    --arg reality_server_name "$REALITY_SERVER_NAME" \
    --arg reality_dest "$REALITY_DEST" \
    --arg reality_short_id "$REALITY_SHORT_ID" \
    --arg ss_password "$SS_PASSWORD" \
    --argjson vless_port "$VLESS_PORT" \
    --argjson ss_port "$SS_PORT" \
    '{
      log: {
        loglevel: "warning"
      },
      inbounds: [
        {
          tag: "vless-reality",
          listen: "0.0.0.0",
          port: $vless_port,
          protocol: "vless",
          settings: {
            clients: [
              {
                id: $vless_uuid,
                flow: "xtls-rprx-vision"
              }
            ],
            decryption: "none"
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: $reality_dest,
              xver: 0,
              serverNames: [$reality_server_name],
              privateKey: $reality_private_key,
              shortIds: [$reality_short_id]
            }
          }
        },
        {
          tag: "shadowsocks-2022",
          listen: "0.0.0.0",
          port: $ss_port,
          protocol: "shadowsocks",
          settings: {
            method: "2022-blake3-aes-128-gcm",
            password: $ss_password,
            network: "tcp,udp"
          }
        }
      ],
      outbounds: [
        {
          tag: "direct",
          protocol: "freedom"
        },
        {
          tag: "block",
          protocol: "blackhole"
        }
      ]
    }' > "$XRAY_CONFIG"

  # Strict permissions for secrets
  chown root:root "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Настраиваем UFW..."
    ufw allow "$VLESS_PORT"/tcp || true
    ufw allow "$SS_PORT"/tcp || true
    ufw allow "$SS_PORT"/udp || true
  else
    log "UFW не установлен — пропускаем настройку файрвола."
  fi
}

restart_xray() {
  log "Проверяем и перезапускаем Xray..."
  xray -test -config "$XRAY_CONFIG"
  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  systemctl --no-pager --full status xray | sed -n '1,20p'
}

generate_links_and_qr() {
  log "Генерируем ссылки и QR-коды..."
  install -d -m 700 "$OUTPUT_DIR"

  local vless_link ss_uri_encoded ss_link

  vless_link="vless://${VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#VLESS-REALITY-${HOST_TAG}"

  # SS-2022 URI format: ss://base64(method:password)@host:port#tag
  ss_uri_encoded="$(printf '2022-blake3-aes-128-gcm:%s' "$SS_PASSWORD" | openssl base64 -A)"
  ss_link="ss://${ss_uri_encoded}@${PUBLIC_IP}:${SS_PORT}#SS2022-${HOST_TAG}"

  cat > "${OUTPUT_DIR}/client-info.txt" <<INFO
==== Server ====
Public IP: ${PUBLIC_IP}

==== VLESS REALITY ====
UUID: ${VLESS_UUID}
Port: ${VLESS_PORT}
ServerName (SNI): ${REALITY_SERVER_NAME}
PublicKey: ${REALITY_PUBLIC_KEY}
ShortID: ${REALITY_SHORT_ID}
Fingerprint: ${REALITY_FINGERPRINT}
Link:
${vless_link}

==== Shadowsocks 2022 ====
Method: 2022-blake3-aes-128-gcm
Password(base64 16 bytes): ${SS_PASSWORD}
Port: ${SS_PORT}
Link:
${ss_link}
INFO

  chmod 600 "${OUTPUT_DIR}/client-info.txt"

  qrencode -t ANSIUTF8 "$vless_link" | tee "${OUTPUT_DIR}/vless-qr.txt"
  qrencode -t ANSIUTF8 "$ss_link" | tee "${OUTPUT_DIR}/ss-qr.txt"
  qrencode -o "${OUTPUT_DIR}/vless-qr.png" -s 8 -m 2 "$vless_link"
  qrencode -o "${OUTPUT_DIR}/ss-qr.png" -s 8 -m 2 "$ss_link"

  chmod 600 "${OUTPUT_DIR}/"*

  log "Файлы клиента:"
  ls -la "$OUTPUT_DIR"
}

print_summary() {
  cat <<EOF_SUMMARY

====================================================
Готово. Shadowsocks + VLESS REALITY настроены.

Пути:
- Конфиг Xray: ${XRAY_CONFIG}
- Данные клиента: ${OUTPUT_DIR}/client-info.txt
- QR PNG:
  - ${OUTPUT_DIR}/vless-qr.png
  - ${OUTPUT_DIR}/ss-qr.png

Полезные команды:
- Проверка конфига: xray -test -config ${XRAY_CONFIG}
- Статус сервиса: systemctl status xray
- Логи: journalctl -u xray -f
====================================================
EOF_SUMMARY
}

main() {
  require_root
  require_ubuntu_24
  install_dependencies
  install_xray
  generate_values
  write_xray_config
  configure_firewall
  restart_xray
  generate_links_and_qr
  print_summary
}

main "$@"
