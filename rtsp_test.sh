#!/bin/bash
 
# ╔══════════════════════════════════════════════════════════╗
# ║           RTSP Stream Analyzer v1.0                      ║
# ╚══════════════════════════════════════════════════════════╝
 
# ─── Настройки ───────────────────────────────────────────────
URL="${1:-rtsp://123:123@123.123.11.11:554/live/main}"
DURATION="${2:-5}"
TIMEOUT=50000000       # Таймаут подключения (мкс)
RETRY_COUNT=3         # Количество попыток подключения
RETRY_DELAY=15         # Задержка между попытками (сек)
LOG_FILE="rtsp_analyzer.log"
 
# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
 
# ─── Утилиты ─────────────────────────────────────────────────
log() {
  local level="$1"
  local msg="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}
 
print_header() {
  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║              RTSP Stream Analyzer v1.0                  ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}
 
print_section() {
  echo -e "\n${BOLD}${CYAN}── $1 ${RESET}"
  echo -e "${CYAN}$(printf '─%.0s' {1..50})${RESET}"
}
 
print_ok()   { echo -e "  ${GREEN}✔${RESET}  $1"; }
print_err()  { echo -e "  ${RED}✘${RESET}  $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
print_info() { echo -e "  ${BLUE}ℹ${RESET}  $1"; }
 
# ─── Проверка зависимостей ────────────────────────────────────
check_dependencies() {
  print_section "Проверка зависимостей"
  local missing=0
 
  for dep in ffmpeg ffprobe bc nc; do
    if command -v "$dep" &>/dev/null; then
      print_ok "$dep — найден ($(command -v $dep))"
    else
      print_err "$dep — НЕ найден"
      (( missing++ ))
    fi
  done
 
  if (( missing > 0 )); then
    print_err "Установи недостающие зависимости и перезапусти скрипт"
    log "ERROR" "Отсутствуют зависимости: $missing"
    exit 1
  fi
}
 
# ─── Парсинг URL ──────────────────────────────────────────────
parse_url() {
  # rtsp://user:pass@host:port/path
  PROTO=$(echo "$URL" | grep -oP '^[a-z]+(?=://)')
  HOST=$(echo "$URL"  | grep -oP '(?<=@)[^:/]+')
  PORT=$(echo "$URL"  | grep -oP '(?<=@[^:]{0,50}:)\d+' || echo "554")
  PATH_=$(echo "$URL" | grep -oP '(?<=\d)/.*$')
  USER=$(echo "$URL"  | grep -oP '(?<=://)[^:]+(?=:)')
 
  # Порт по умолчанию если не указан
  [[ -z "$PORT" ]] && PORT="554"
}
 
# ─── Проверка сети ────────────────────────────────────────────
check_network() {
  print_section "Проверка сети"
 
  # ICMP Ping
  print_info "ICMP ping → $HOST"
  if ping -c 3 -W 2 "$HOST" &>/dev/null; then
    local rtt
    rtt=$(ping -c 3 -W 2 "$HOST" 2>/dev/null | tail -1 | grep -oP 'avg = \K[\d.]+' || \
          ping -c 3 -W 2 "$HOST" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    print_ok "Хост доступен | RTT avg: ${rtt}ms"
    log "INFO" "Ping OK, RTT: ${rtt}ms"
  else
    print_warn "ICMP недоступен (возможно заблокирован firewall)"
    log "WARN" "Ping failed to $HOST"
  fi
 
  # TCP Port check
  print_info "TCP проверка порта $PORT"
  if nc -zw 3 "$HOST" "$PORT" &>/dev/null; then
    print_ok "Порт $PORT — открыт"
    log "INFO" "Port $PORT open"
  else
    print_err "Порт $PORT — закрыт или недоступен"
    log "ERROR" "Port $PORT closed on $HOST"
    read -p " "
    exit 1
  fi
}
 
# ─── RTSP OPTIONS запрос ──────────────────────────────────────
check_rtsp_handshake() {
  print_section "RTSP Handshake"
 
  print_info "Отправка RTSP OPTIONS запроса..."
 
  local response
  local start end elapsed
 
  start=$(date +%s%3N)
 
  response=$(
    (
      printf "OPTIONS %s RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: RTSPAnalyzer\r\n\r\n" "$URL"
      sleep 2
    ) | nc -w 3 "$HOST" "$PORT" 2>/dev/null
  )
 
  end=$(date +%s%3N)
  elapsed=$(( end - start ))
 
  if echo "$response" | grep -q "RTSP/1.0 200"; then
    print_ok "RTSP сервер отвечает | Время ответа: ${elapsed}ms"
    log "INFO" "RTSP OPTIONS OK, ${elapsed}ms"
 
    # Вывод поддерживаемых методов
    local methods
    methods=$(echo "$response" | grep -i "Public:" | sed 's/Public: //')
    [[ -n "$methods" ]] && print_info "Методы: $methods"
 
  elif echo "$response" | grep -q "401"; then
    print_warn "Сервер требует авторизацию (401) — это нормально"
    log "WARN" "RTSP 401 Unauthorized"
  else
    print_warn "Нестандартный ответ (попытаемся подключиться)"
    log "WARN" "Unexpected RTSP response"
  fi
}
 
# ─── Подключение к потоку с ретраями ─────────────────────────
connect_with_retry() {
  print_section "Подключение к потоку"
 
  for (( i=1; i<=RETRY_COUNT; i++ )); do
    print_info "Попытка $i/$RETRY_COUNT..."

    if ffprobe -v error -rtsp_transport tcp -i "$URL" -show_entries format=filename -of default=noprint_wrappers=1:nokey=1 
> /dev/null 2>&1; then
      print_ok "Подключение успешно"
      log "INFO" "Connected on attempt $i"
      return 0
    fi
 
    if (( i < RETRY_COUNT )); then
      print_warn "Нет ответа, повтор через ${RETRY_DELAY}с..."
      sleep "$RETRY_DELAY"
    fi
  done
 
  print_err "Не удалось подключиться после $RETRY_COUNT попыток"
  log "ERROR" "Failed to connect after $RETRY_COUNT attempts"
  exit 1
}
 
# ─── Анализ метаданных потока ─────────────────────────────────
analyze_stream_meta() {
  print_section "Метаданные потока"
 
  local meta
  meta=$(ffprobe \
    -rtsp_transport tcp \
    -analyzeduration 3000000 \
    -probesize 1000000 \
    -i "$URL" \
    -v error \
    -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt,profile,level \
    -of json 2>/dev/null)
 
  CODEC=$(echo "$meta"      | grep -oP '"codec_name":\s*"\K[^"]+')
  WIDTH=$(echo "$meta"      | grep -oP '"width":\s*\K\d+')
  HEIGHT=$(echo "$meta"     | grep -oP '"height":\s*\K\d+')
  FRAMERATE=$(echo "$meta"  | grep -oP '"r_frame_rate":\s*"\K[^"]+')
  PIX_FMT=$(echo "$meta"    | grep -oP '"pix_fmt":\s*"\K[^"]+')
  PROFILE=$(echo "$meta"    | grep -oP '"profile":\s*"\K[^"]+')
 
  # Считаем FPS из дроби
  FPS=$(echo "scale=2; $FRAMERATE" | bc 2>/dev/null || echo "$FRAMERATE")
 
  [[ -n "$CODEC" ]]     && print_info "Кодек       : ${BOLD}$CODEC${RESET}"
  [[ -n "$WIDTH" ]]     && print_info "Разрешение  : ${BOLD}${WIDTH}x${HEIGHT}${RESET}"
  [[ -n "$FPS" ]]       && print_info "FPS         : ${BOLD}$FPS${RESET}"
  [[ -n "$PIX_FMT" ]]   && print_info "Пиксельный  : ${BOLD}$PIX_FMT${RESET}"
  [[ -n "$PROFILE" ]]   && print_info "Профиль     : ${BOLD}$PROFILE${RESET}"
 
  log "INFO" "Stream: ${CODEC} ${WIDTH}x${HEIGHT} @ ${FPS}fps"
}
 
# ─── Замер битрейта ───────────────────────────────────────────
measure_bitrate() {
  print_section "Замер битрейта (${DURATION}с)"
 
  print_info "Получение данных потока..."
 
  local start end elapsed_real bytes
  start=$(date +%s%3N)
 
  bytes=$(ffmpeg \
    -y \
    -rtsp_transport tcp \
    -i "$URL" \
    -t "$DURATION" \
    -c copy \
    -f mpegts - 2>/dev/null | wc -c)
 
  end=$(date +%s%3N)
  elapsed_real=$(echo "scale=2; ($end - $start) / 1000" | bc)
 
  if [[ "$bytes" -eq 0 ]]; then
    print_err "Получено 0 байт — поток не передаёт данные"
    log "ERROR" "0 bytes received"
    return 1
  fi
 
  local kbps mbps kbytes mbytes
  kbps=$(( bytes * 8 / DURATION / 1024 ))
  mbps=$(echo "scale=2; $bytes * 8 / $DURATION / 1024 / 1024" | bc)
  kbytes=$(( bytes / 1024 ))
  mbytes=$(echo "scale=2; $bytes / 1024 / 1024" | bc)
 
  print_ok "Получено данных : ${kbytes} KB (${mbytes} MB)"
  print_ok "Реальное время  : ${elapsed_real}с"
  print_ok "Битрейт         : ${BOLD}${kbps} kbps${RESET}"
  print_ok "Битрейт         : ${BOLD}${mbps} Mbps${RESET}"
 
  # Оценка качества
  print_section "Оценка качества"
  if (( kbps < 500 )); then
    print_warn "Битрейт очень низкий — возможно плохое качество картинки"
  elif (( kbps < 1500 )); then
    print_info "Битрейт низкий — SD качество"
  elif (( kbps < 4000 )); then
    print_ok "Битрейт средний — HD качество"
  elif (( kbps < 8000 )); then
    print_ok "Битрейт высокий — Full HD качество"
  else
    print_ok "Битрейт очень высокий — 4K / высокодетальный поток"
  fi
 
  log "INFO" "Bitrate: ${kbps} kbps, bytes: $bytes"
}
 
# ─── Итоговый отчёт ───────────────────────────────────────────
print_report() {
  print_section "Итоговый отчёт"
  print_info "URL    : $URL"
  print_info "Хост   : $HOST:$PORT"
  print_info "Лог    : $LOG_FILE"
  echo -e "\n${GREEN}${BOLD}  Анализ завершён успешно${RESET}\n"
}
 
# ─── Точка входа ──────────────────────────────────────────────
main() {
  print_header
  log "INFO" "=== Запуск анализа: $URL ==="
 
  parse_url
  check_dependencies
  check_network
  check_rtsp_handshake
  connect_with_retry
  analyze_stream_meta
  measure_bitrate
  print_report
}
 
main
read -p "  "