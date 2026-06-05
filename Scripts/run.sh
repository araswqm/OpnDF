#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="OpnDF"
DEFAULT_APP_DIR="${OPNDF_APP_DIR:-${HOME}/OpnDF}"
PREFERENCES_FILE="${OPNDF_PREFERENCES_FILE:-${DEFAULT_APP_DIR}/preferences.txt}"
RUN_ONCE="false"
SKIP_FETCH="false"

for arg in "$@"; do
  case "${arg}" in
    --once) RUN_ONCE="true" ;;
    --no-fetch) SKIP_FETCH="true" ;;
  esac
done

SEND_NOTIFICATIONS="${SEND_NOTIFICATIONS:-true}"

log_message() {
  local message="$1"
  local log_dir="${APP_DIR:-${DEFAULT_APP_DIR}}"
  mkdir -p "${log_dir}" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%F %T')" "${message}" >> "${log_dir}/opndf.log" 2>/dev/null || true
}

notify_user() {
  local title="$1"
  local body="$2"
  log_message "${title}: ${body//$'\n'/ | }"

  if [[ "${SEND_NOTIFICATIONS:-true}" == "true" ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${body}" >/dev/null 2>&1 || true
  else
    printf '%s: %s\n' "${title}" "${body}" >&2 || true
  fi
}

if [[ ! -f "${PREFERENCES_FILE}" ]]; then
  APP_DIR="${DEFAULT_APP_DIR}"
  notify_user "${APP_NAME}" "preferences.txt bulunamadı. Lütfen OpnDF kurulumunu tekrar çalıştırın."
  exit 1
fi

# preferences.txt kurulum betiği tarafından shell-quote edilerek yazılır.
source "${PREFERENCES_FILE}"

APP_DIR="${APP_DIR:-${DEFAULT_APP_DIR}}"
BOOKS_DIR="${BOOKS_DIR:-${HOME}/Masaüstü/OpnDF Kitaplar}"
SCHEDULE_FILE="${APP_DIR}/schedule.json"
LOCK_FILE="${APP_DIR}/opndf.lock"
RAW_BASE="${OPNDF_RAW_BASE:-${RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER:-araswqm}/${REPO_NAME:-OpnDF}/${REPO_BRANCH:-main}}}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-30}"
SEND_NOTIFICATIONS="${SEND_NOTIFICATIONS:-true}"
OPEN_TEACHER_GREETING="${OPEN_TEACHER_GREETING:-true}"
AUTO_OPEN="${AUTO_OPEN:-true}"

mkdir -p "${APP_DIR}" "${BOOKS_DIR}"

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
      notify_user "${APP_NAME}" "OpnDF zaten çalışıyor. Ders saati geldiğinde ilgili PDF otomatik açılacak."
      exit 0
    fi
  else
    local lock_dir="${APP_DIR}/.opndf.lockdir"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
      notify_user "${APP_NAME}" "OpnDF zaten çalışıyor. Ders saati geldiğinde ilgili PDF otomatik açılacak."
      exit 0
    fi
    trap 'rmdir "${lock_dir}" 2>/dev/null || true' EXIT
  fi
}

require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    notify_user "${APP_NAME}" "Python 3 bulunamadı. OpnDF ders programını okuyamıyor."
    exit 1
  fi
}

urlencode_path() {
  python3 - "$1" <<'PY'
from urllib.parse import quote
import sys

print("/".join(quote(part, safe="") for part in sys.argv[1].split("/")))
PY
}

raw_url_for() {
  local remote_path="$1"
  printf '%s/%s\n' "${RAW_BASE%/}" "$(urlencode_path "${remote_path}")"
}

download_to() {
  local remote_path="$1"
  local destination="$2"
  local url
  url="$(raw_url_for "${remote_path}")"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --retry 1 "${url}" -o "${destination}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=15 --tries=1 "${url}" -O "${destination}"
  else
    return 1
  fi
}

validate_json() {
  python3 -m json.tool "$1" >/dev/null 2>&1
}

add_schedule_path() {
  local candidate="$1"
  local existing=""
  [[ -n "${candidate}" ]] || return 0

  for existing in "${schedule_paths[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  schedule_paths+=("${candidate}")
}

fetch_schedule() {
  [[ "${SKIP_FETCH}" == "true" ]] && return 0

  local tmp="${SCHEDULE_FILE}.tmp"
  local remote_path=""
  schedule_paths=()

  add_schedule_path "${SCHEDULE_REMOTE_PATH:-}"

  if [[ -n "${DEPARTMENT:-}" && -n "${GRADE:-}" ]]; then
    if [[ -n "${SECTION:-}" ]]; then
      add_schedule_path "Schedules/${DEPARTMENT}/${GRADE}/${SECTION}/schedule.json"
    fi
    add_schedule_path "Schedules/${DEPARTMENT}/${GRADE}/schedule.json"
  fi

  for remote_path in "${schedule_paths[@]}"; do
    rm -f "${tmp}"
    if download_to "${remote_path}" "${tmp}" 2>/dev/null && validate_json "${tmp}"; then
      mv "${tmp}" "${SCHEDULE_FILE}"
      log_message "Ders programı güncellendi: ${remote_path}"
      return 0
    fi
  done

  rm -f "${tmp}"
  if [[ -s "${SCHEDULE_FILE}" ]] && validate_json "${SCHEDULE_FILE}"; then
    log_message "Ders programı indirilemedi, yerel kopya kullanılacak."
    return 0
  fi

  notify_user "${APP_NAME}" "Ders programı indirilemedi ve yerel schedule.json bulunamadı."
  exit 1
}

run_scheduler() {
  export APP_NAME APP_DIR BOOKS_DIR SCHEDULE_FILE CHECK_INTERVAL_SECONDS
  export SEND_NOTIFICATIONS OPEN_TEACHER_GREETING AUTO_OPEN RUN_ONCE

  python3 <<'PY'
import datetime as dt
import json
import os
import random
import shutil
import subprocess
import sys
import time

APP_NAME = os.environ.get("APP_NAME", "OpnDF")
APP_DIR = os.environ["APP_DIR"]
BOOKS_DIR = os.environ["BOOKS_DIR"]
SCHEDULE_FILE = os.environ["SCHEDULE_FILE"]
SEND_NOTIFICATIONS = os.environ.get("SEND_NOTIFICATIONS", "true") == "true"
OPEN_TEACHER_GREETING = os.environ.get("OPEN_TEACHER_GREETING", "true") == "true"
AUTO_OPEN = os.environ.get("AUTO_OPEN", "true") == "true"
RUN_ONCE = os.environ.get("RUN_ONCE", "false") == "true"

try:
    CHECK_INTERVAL_SECONDS = int(os.environ.get("CHECK_INTERVAL_SECONDS", "30"))
except ValueError:
    CHECK_INTERVAL_SECONDS = 30
CHECK_INTERVAL_SECONDS = max(5, min(600, CHECK_INTERVAL_SECONDS))

WEEKDAYS = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"]
GREETINGS = [
    "İyi dersler, {teacher}!",
    "Bugün ne öğreniyoruz, {teacher}?",
    "Keyifli dersler, {teacher}!",
    "Ders vakti, {teacher}!",
    "Hazırız, {teacher}!"
]


def log(message):
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        with open(os.path.join(APP_DIR, "opndf.log"), "a", encoding="utf-8") as handle:
            handle.write(f"[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {message}\n")
    except OSError:
        pass


def notify(title, body):
    log(f"{title}: {body.replace(chr(10), ' | ')}")
    if SEND_NOTIFICATIONS and shutil.which("notify-send"):
        subprocess.Popen(
            ["notify-send", title, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        print(f"{title}: {body}", file=sys.stderr)


def load_schedule():
    try:
        with open(SCHEDULE_FILE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        notify(APP_NAME, f"schedule.json okunamadı: {exc}")
        raise SystemExit(1)


def parse_clock(value):
    try:
        hour_text, minute_text = str(value).strip().split(":", 1)
        hour = int(hour_text)
        minute = int(minute_text)
    except (TypeError, ValueError):
        return None

    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return hour, minute


def today_lessons(schedule, now):
    day_name = WEEKDAYS[now.weekday()]
    lessons = []
    for item in schedule.get("ders_programi", {}).get(day_name, []):
        start_clock = parse_clock(item.get("baslangic"))
        end_clock = parse_clock(item.get("bitis"))
        lesson_name = str(item.get("ders_adi", "")).strip()
        if not start_clock or not end_clock or not lesson_name:
            continue

        start = now.replace(hour=start_clock[0], minute=start_clock[1], second=0, microsecond=0)
        end = now.replace(hour=end_clock[0], minute=end_clock[1], second=0, microsecond=0)
        if end <= start:
            end += dt.timedelta(days=1)

        lessons.append(
            {
                "start": start,
                "end": end,
                "name": lesson_name,
                "teacher": str(item.get("ogretmen", "")).strip(),
            }
        )

    lessons.sort(key=lambda lesson: lesson["start"])
    return day_name, lessons


def lesson_key(lesson):
    return f"{lesson['start']:%Y-%m-%d %H:%M}|{lesson['end']:%H:%M}|{lesson['name']}"


def find_pdf(lesson_name):
    target = f"{lesson_name}.pdf"
    exact = os.path.join(BOOKS_DIR, target)
    if os.path.isfile(exact):
        return exact

    try:
        for entry in os.listdir(BOOKS_DIR):
            candidate = os.path.join(BOOKS_DIR, entry)
            if os.path.isfile(candidate) and entry.casefold() == target.casefold():
                return candidate
    except FileNotFoundError:
        return None
    return None


def open_lesson(lesson):
    teacher = lesson.get("teacher", "")
    lesson_name = lesson["name"]
    lines = []

    if teacher and OPEN_TEACHER_GREETING:
        lines.append(random.choice(GREETINGS).format(teacher=teacher))
    else:
        lines.append("Ders başladı.")
    lines.append(lesson_name)

    pdf_path = find_pdf(lesson_name)
    if pdf_path and AUTO_OPEN:
        opener = shutil.which("xdg-open")
        if opener:
            subprocess.Popen(
                [opener, pdf_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            lines.append("PDF açılıyor.")
            log(f"PDF açıldı: {pdf_path}")
        else:
            lines.append("xdg-open bulunamadı; PDF otomatik açılamadı.")
            log("xdg-open bulunamadı.")
    elif pdf_path:
        lines.append("PDF hazır.")
        log(f"PDF bulundu: {pdf_path}")
    else:
        lines.append(f"PDF bulunamadı: {lesson_name}.pdf")
        lines.append(f"Klasör: {BOOKS_DIR}")
        log(f"PDF bulunamadı: {lesson_name}.pdf")

    notify(APP_NAME, "\n".join(lines))


def seconds_until(moment):
    return max(1, int((moment - dt.datetime.now()).total_seconds()))


def main():
    opened = set()

    while True:
        schedule = load_schedule()
        now = dt.datetime.now()
        day_name, lessons = today_lessons(schedule, now)

        if not lessons:
            notify(APP_NAME, f"Bugün ({day_name}) ders programı yok.")
            return

        current_lessons = [lesson for lesson in lessons if lesson["start"] <= now < lesson["end"]]
        for lesson in current_lessons:
            key = lesson_key(lesson)
            if key not in opened:
                open_lesson(lesson)
                opened.add(key)

        if RUN_ONCE:
            if not current_lessons:
                future = [lesson for lesson in lessons if lesson["start"] > now]
                if future:
                    notify(APP_NAME, f"Şu anda ders yok. Sıradaki ders {future[0]['start']:%H:%M}: {future[0]['name']}")
                else:
                    notify(APP_NAME, "Bugünün dersleri bitti.")
            return

        last_end = max(lesson["end"] for lesson in lessons)
        if now >= last_end:
            notify(APP_NAME, "Bugünün dersleri bitti.")
            return

        boundaries = []
        if current_lessons:
            boundaries.append(min(lesson["end"] for lesson in current_lessons))

        future_starts = [
            lesson["start"]
            for lesson in lessons
            if lesson["start"] > now and lesson_key(lesson) not in opened
        ]
        if future_starts:
            boundaries.append(min(future_starts))

        if not boundaries:
            boundaries.append(last_end)

        sleep_for = min(CHECK_INTERVAL_SECONDS, seconds_until(min(boundaries)))
        time.sleep(max(1, sleep_for))


if __name__ == "__main__":
    main()
PY
}

require_python
acquire_lock
fetch_schedule
run_scheduler
