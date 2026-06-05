#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="OpnDF"
REPO_OWNER="${OPNDF_REPO_OWNER:-araswqm}"
REPO_NAME="${OPNDF_REPO_NAME:-OpnDF}"
REPO_BRANCH="${OPNDF_REPO_BRANCH:-main}"
RAW_BASE="${OPNDF_RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
APP_DIR="${OPNDF_APP_DIR:-${HOME}/OpnDF}"
PREFERENCES_FILE="${APP_DIR}/preferences.txt"
SCHEDULE_FILE="${APP_DIR}/schedule.json"
MISSING_PDFS_FILE="${APP_DIR}/missing-pdfs.txt"
RUN_SCRIPT="${APP_DIR}/run.sh"
MANIFEST_FILE=""

die() {
  ui_error "$1"
  exit 1
}

cleanup_manifest() {
  [[ -n "${MANIFEST_FILE:-}" ]] && rm -f "${MANIFEST_FILE}"
}

detect_desktop_dir() {
  local dir=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi

  if [[ -n "${dir}" && "${dir}" != "${HOME}" ]]; then
    printf '%s\n' "${dir}"
  elif [[ -d "${HOME}/Masaüstü" ]]; then
    printf '%s\n' "${HOME}/Masaüstü"
  elif [[ -d "${HOME}/Desktop" ]]; then
    printf '%s\n' "${HOME}/Desktop"
  else
    printf '%s\n' "${HOME}/Masaüstü"
  fi
}

DESKTOP_DIR="${OPNDF_DESKTOP_DIR:-$(detect_desktop_dir)}"
BOOKS_DIR="${OPNDF_BOOKS_DIR:-${DESKTOP_DIR}/OpnDF Kitaplar}"
AUTOSTART_DIR="${HOME}/.config/autostart"

detect_ui_backend() {
  if [[ -n "${OPNDF_NO_GUI:-}" ]]; then
    printf 'terminal\n'
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
    printf 'zenity\n'
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v yad >/dev/null 2>&1; then
    printf 'yad\n'
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v kdialog >/dev/null 2>&1; then
    printf 'kdialog\n'
  else
    printf 'terminal\n'
  fi
}

UI_BACKEND="$(detect_ui_backend)"

ui_info() {
  local text="$1"
  case "${UI_BACKEND}" in
    zenity) zenity --info --title="${APP_NAME} Kurulum" --width=520 --text="${text}" >/dev/null 2>&1 || true ;;
    yad) yad --info --title="${APP_NAME} Kurulum" --width=520 --text="${text}" >/dev/null 2>&1 || true ;;
    kdialog) kdialog --title "${APP_NAME} Kurulum" --msgbox "${text}" >/dev/null 2>&1 || true ;;
    *) printf '\n%s\n' "${text}" ;;
  esac
}

ui_error() {
  local text="$1"
  case "${UI_BACKEND}" in
    zenity) zenity --error --title="${APP_NAME} Kurulum" --width=520 --text="${text}" >/dev/null 2>&1 || true ;;
    yad) yad --error --title="${APP_NAME} Kurulum" --width=520 --text="${text}" >/dev/null 2>&1 || true ;;
    kdialog) kdialog --title "${APP_NAME} Kurulum" --error "${text}" >/dev/null 2>&1 || true ;;
    *) printf '\nHata: %s\n' "${text}" >&2 ;;
  esac
}

ui_choose() {
  local title="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  local choice=""

  case "${UI_BACKEND}" in
    zenity)
      choice="$(zenity --list --title="${title}" --text="${prompt}" --column="Seçim" --height=280 --width=480 "${options[@]}")" || return 1
      ;;
    yad)
      choice="$(yad --list --title="${title}" --text="${prompt}" --column="Seçim" --height=280 --width=480 "${options[@]}")" || return 1
      choice="${choice%%|*}"
      ;;
    kdialog)
      choice="$(kdialog --title "${title}" --combobox "${prompt}" "${options[@]}")" || return 1
      ;;
    *)
      printf '\n%s\n' "${prompt}" >&2
      PS3="Seçiminiz: "
      select choice in "${options[@]}"; do
        [[ -n "${choice}" ]] && break
        printf 'Geçerli bir seçim yapın.\n' >&2
      done
      ;;
  esac

  [[ -n "${choice}" ]] || return 1
  printf '%s\n' "${choice}"
}

ui_yes_no() {
  local prompt="$1"
  case "${UI_BACKEND}" in
    zenity) zenity --question --title="${APP_NAME} Kurulum" --width=520 --ok-label="Evet" --cancel-label="Hayır" --text="${prompt}" >/dev/null 2>&1 ;;
    yad) yad --question --title="${APP_NAME} Kurulum" --width=520 --button="Evet:0" --button="Hayır:1" --text="${prompt}" >/dev/null 2>&1 ;;
    kdialog) kdialog --title "${APP_NAME} Kurulum" --yesno "${prompt}" >/dev/null 2>&1 ;;
    *)
      local reply=""
      printf '%s [E/h]: ' "${prompt}" >&2
      read -r reply || true
      reply="$(printf '%s' "${reply}" | tr '[:upper:]' '[:lower:]')"
      [[ -z "${reply}" || "${reply}" == "e" || "${reply}" == "evet" || "${reply}" == "y" || "${reply}" == "yes" ]]
      ;;
  esac
}

require_command() {
  local command_name="$1"
  local friendly_name="$2"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    die "${friendly_name} bulunamadı. Lütfen ${friendly_name} kurulu olduğundan emin olun."
  fi
}

has_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
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
    curl -fsSL --connect-timeout 20 --retry 2 "${url}" -o "${destination}"
  else
    wget -q --timeout=20 --tries=2 "${url}" -O "${destination}"
  fi
}

validate_json() {
  python3 -m json.tool "$1" >/dev/null 2>&1
}

write_fallback_manifest() {
  local destination="$1"
  cat > "${destination}" <<'JSON'
{
  "version": 1,
  "app": "OpnDF",
  "departments": [
    {
      "id": "YET",
      "name": "Yenilenebilir Enerji Teknolojileri",
      "grades": [
        {"id": "9", "sections": [{"id": "A", "schedule": "Schedules/YET/9/A/schedule.json"}, {"id": "B", "schedule": "Schedules/YET/9/B/schedule.json"}]},
        {"id": "10", "sections": [{"id": "", "schedule": "Schedules/YET/10/schedule.json"}]},
        {"id": "11", "sections": [{"id": "", "schedule": "Schedules/YET/11/schedule.json"}]},
        {"id": "12", "sections": [{"id": "", "schedule": "Schedules/YET/12/schedule.json"}]}
      ]
    },
    {
      "id": "LOJ",
      "name": "Lojistik",
      "grades": [
        {"id": "9", "sections": [{"id": "A", "schedule": "Schedules/LOJ/9/A/schedule.json"}]},
        {"id": "10", "sections": [{"id": "", "schedule": "Schedules/LOJ/10/schedule.json"}]},
        {"id": "11", "sections": [{"id": "", "schedule": "Schedules/LOJ/11/schedule.json"}]},
        {"id": "12", "sections": [{"id": "", "schedule": "Schedules/LOJ/12/schedule.json"}]}
      ]
    }
  ]
}
JSON
}

local_file_for() {
  local remote_path="$1"
  local candidate=""

  for candidate in \
    "${SCRIPT_DIR}/../${remote_path}" \
    "${SCRIPT_DIR}/${remote_path}" \
    "$(pwd -P)/${remote_path}"; do
    if [[ -s "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

prepare_manifest() {
  local manifest_file="$1"
  local local_manifest=""

  if local_manifest="$(local_file_for "manifest.json")"; then
    cp "${local_manifest}" "${manifest_file}"
  elif download_to "manifest.json" "${manifest_file}" && validate_json "${manifest_file}"; then
    :
  else
    write_fallback_manifest "${manifest_file}"
  fi
}

manifest_query() {
  local manifest_file="$1"
  shift
  python3 - "${manifest_file}" "$@" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
operation = sys.argv[2]
args = sys.argv[3:]

with open(manifest_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)


def department(dep_id):
    for dep in data.get("departments", []):
        if dep.get("id") == dep_id:
            return dep
    raise SystemExit(2)


def grade(dep_id, grade_id):
    dep = department(dep_id)
    for item in dep.get("grades", []):
        if item.get("id") == grade_id:
            return item
    raise SystemExit(2)


if operation == "departments":
    for dep in data.get("departments", []):
        print(dep.get("id", ""))
elif operation == "department_name":
    print(department(args[0]).get("name", args[0]))
elif operation == "grades":
    for item in department(args[0]).get("grades", []):
        print(item.get("id", ""))
elif operation == "sections":
    for item in grade(args[0], args[1]).get("sections", []):
        section_id = item.get("id", "")
        if section_id:
            print(section_id)
elif operation == "schedule":
    dep_id, grade_id, section_id = args
    item = grade(dep_id, grade_id)
    sections = item.get("sections", [])
    for section in sections:
        if section.get("id", "") == section_id:
            print(section.get("schedule", ""))
            break
    else:
        if section_id:
            print(f"Schedules/{dep_id}/{grade_id}/{section_id}/schedule.json")
        else:
            print(f"Schedules/{dep_id}/{grade_id}/schedule.json")
else:
    raise SystemExit(2)
PY
}

install_run_script() {
  local tmp="${RUN_SCRIPT}.tmp"
  local local_run=""

  mkdir -p "${APP_DIR}"
  if [[ -s "${SCRIPT_DIR}/run.sh" ]]; then
    cp "${SCRIPT_DIR}/run.sh" "${tmp}"
  elif local_run="$(local_file_for "Scripts/run.sh")"; then
    cp "${local_run}" "${tmp}"
  elif download_to "Scripts/run.sh" "${tmp}"; then
    :
  else
    rm -f "${tmp}"
    die "run.sh indirilemedi. İnternet bağlantısını ve repo adresini kontrol edin."
  fi

  mv "${tmp}" "${RUN_SCRIPT}"
  chmod +x "${RUN_SCRIPT}"
}

install_schedule() {
  local remote_path="$1"
  local tmp="${SCHEDULE_FILE}.tmp"
  local local_schedule=""

  if local_schedule="$(local_file_for "${remote_path}")"; then
    cp "${local_schedule}" "${tmp}"
  elif download_to "${remote_path}" "${tmp}"; then
    :
  else
    rm -f "${tmp}"
    die "Ders programı indirilemedi: ${remote_path}"
  fi

  if ! validate_json "${tmp}"; then
    rm -f "${tmp}"
    die "İndirilen ders programı geçerli JSON değil: ${remote_path}"
  fi

  mv "${tmp}" "${SCHEDULE_FILE}"
}

extract_subjects() {
  python3 - "${SCHEDULE_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

subjects = set()
for lessons in data.get("ders_programi", {}).values():
    for lesson in lessons:
        name = str(lesson.get("ders_adi", "")).strip()
        if name:
            subjects.add(name)

for subject in sorted(subjects, key=str.casefold):
    print(subject)
PY
}

try_download_pdf() {
  local subject="$1"
  local destination="${BOOKS_DIR}/${subject}.pdf"
  local tmp="${destination}.tmp"
  local candidates=()
  local remote_path=""

  [[ -f "${destination}" ]] && return 0

  if [[ -n "${SECTION}" ]]; then
    candidates+=("PDF's/${DEPARTMENT}/${GRADE}/${SECTION}/${subject}.pdf")
  fi
  candidates+=(
    "PDF's/${DEPARTMENT}/${GRADE}/${subject}.pdf"
    "PDF's/${DEPARTMENT}/${subject}.pdf"
    "PDF's/${subject}.pdf"
  )

  for remote_path in "${candidates[@]}"; do
    rm -f "${tmp}"
    if download_to "${remote_path}" "${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
      mv "${tmp}" "${destination}"
      return 0
    fi
  done

  rm -f "${tmp}"
  return 1
}

write_preferences() {
  local tmp="${PREFERENCES_FILE}.tmp"
  local installed_at
  installed_at="$(date -Is)"

  write_pref() {
    printf '%s=%q\n' "$1" "$2"
  }

  {
    printf '# OpnDF ayarlari. Bu dosya kurulum tarafindan olusturuldu.\n'
    write_pref "OPNDF_VERSION" "1"
    write_pref "DEPARTMENT" "${DEPARTMENT}"
    write_pref "DEPARTMENT_NAME" "${DEPARTMENT_NAME}"
    write_pref "GRADE" "${GRADE}"
    write_pref "SECTION" "${SECTION}"
    write_pref "APP_DIR" "${APP_DIR}"
    write_pref "BOOKS_DIR" "${BOOKS_DIR}"
    write_pref "SCHEDULE_REMOTE_PATH" "${SCHEDULE_REMOTE_PATH}"
    write_pref "REPO_OWNER" "${REPO_OWNER}"
    write_pref "REPO_NAME" "${REPO_NAME}"
    write_pref "REPO_BRANCH" "${REPO_BRANCH}"
    write_pref "RAW_BASE" "${RAW_BASE}"
    write_pref "AUTO_START" "${AUTO_START}"
    write_pref "SEND_NOTIFICATIONS" "${SEND_NOTIFICATIONS}"
    write_pref "OPEN_TEACHER_GREETING" "true"
    write_pref "CHECK_INTERVAL_SECONDS" "30"
    write_pref "INSTALLED_AT" "${installed_at}"
  } > "${tmp}"

  mv "${tmp}" "${PREFERENCES_FILE}"
  chmod 600 "${PREFERENCES_FILE}"
}

quote_desktop_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

create_desktop_entry() {
  local destination="$1"
  local name="$2"
  local exec_path
  exec_path="$(quote_desktop_value "${RUN_SCRIPT}")"

  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Version=1.0\n'
    printf 'Name=%s\n' "${name}"
    printf 'Comment=Ders saatinde ilgili OpnDF PDF kitabini acar\n'
    printf 'Exec=/bin/bash %s\n' "${exec_path}"
    printf 'Path=%s\n' "${APP_DIR}"
    printf 'Icon=application-pdf\n'
    printf 'Terminal=false\n'
    printf 'Categories=Education;Utility;\n'
    printf 'StartupNotify=false\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
  } > "${destination}"

  chmod +x "${destination}"
}

install_launchers() {
  mkdir -p "${DESKTOP_DIR}" "${AUTOSTART_DIR}"

  create_desktop_entry "${DESKTOP_DIR}/OpnDF.autostart" "OpnDF"
  create_desktop_entry "${DESKTOP_DIR}/OpnDF.desktop" "OpnDF"

  if [[ "${AUTO_START}" == "true" ]]; then
    create_desktop_entry "${AUTOSTART_DIR}/OpnDF.autostart" "OpnDF"
    create_desktop_entry "${AUTOSTART_DIR}/OpnDF.desktop" "OpnDF"
  else
    rm -f "${AUTOSTART_DIR}/OpnDF.autostart" "${AUTOSTART_DIR}/OpnDF.desktop"
  fi
}

main() {
  require_command "python3" "Python 3"
  has_downloader || die "Kurulum için curl veya wget gerekli."

  ui_info "OpnDF kurulumu başlayacak.

Kurulum bölüm, sınıf ve şube seçiminizi alacak; ders programını indirip PDF kitap klasörünü hazırlayacak."

  MANIFEST_FILE="$(mktemp -t opndf-manifest.XXXXXX.json)"
  trap cleanup_manifest EXIT
  prepare_manifest "${MANIFEST_FILE}"

  mapfile -t departments < <(manifest_query "${MANIFEST_FILE}" "departments")
  [[ "${#departments[@]}" -gt 0 ]] || die "Manifest içinde bölüm seçeneği bulunamadı."

  DEPARTMENT="${OPNDF_DEPARTMENT:-}"
  if [[ -z "${DEPARTMENT}" ]]; then
    DEPARTMENT="$(ui_choose "Bölüm Seçimi" "Bölümünüzü seçin:" "${departments[@]}")" || die "Kurulum iptal edildi."
  fi

  DEPARTMENT_NAME="$(manifest_query "${MANIFEST_FILE}" "department_name" "${DEPARTMENT}")"

  mapfile -t grades < <(manifest_query "${MANIFEST_FILE}" "grades" "${DEPARTMENT}")
  [[ "${#grades[@]}" -gt 0 ]] || die "${DEPARTMENT} bölümü için sınıf seçeneği bulunamadı."

  GRADE="${OPNDF_GRADE:-}"
  if [[ -z "${GRADE}" ]]; then
    GRADE="$(ui_choose "Sınıf Seçimi" "Sınıfınızı seçin:" "${grades[@]}")" || die "Kurulum iptal edildi."
  fi

  mapfile -t sections < <(manifest_query "${MANIFEST_FILE}" "sections" "${DEPARTMENT}" "${GRADE}")
  SECTION="${OPNDF_SECTION:-}"
  if [[ -z "${SECTION}" && "${#sections[@]}" -gt 0 ]]; then
    SECTION="$(ui_choose "Şube Seçimi" "Şubenizi seçin:" "${sections[@]}")" || die "Kurulum iptal edildi."
  fi

  SCHEDULE_REMOTE_PATH="$(manifest_query "${MANIFEST_FILE}" "schedule" "${DEPARTMENT}" "${GRADE}" "${SECTION}")"

  if [[ -z "${OPNDF_AUTO_START:-}" ]]; then
    if ui_yes_no "OpnDF oturum açıldığında otomatik çalışsın mı?"; then
      AUTO_START="true"
    else
      AUTO_START="false"
    fi
  else
    AUTO_START="${OPNDF_AUTO_START}"
  fi

  if [[ -z "${OPNDF_SEND_NOTIFICATIONS:-}" ]]; then
    if ui_yes_no "Ders açıldığında öğretmen selamlaması ve bilgi bildirimi gösterilsin mi?"; then
      SEND_NOTIFICATIONS="true"
    else
      SEND_NOTIFICATIONS="false"
    fi
  else
    SEND_NOTIFICATIONS="${OPNDF_SEND_NOTIFICATIONS}"
  fi

  mkdir -p "${APP_DIR}" "${BOOKS_DIR}"

  ui_info "Dosyalar hazırlanıyor.

OpnDF klasörü:
${APP_DIR}

Kitap klasörü:
${BOOKS_DIR}"

  install_run_script
  install_schedule "${SCHEDULE_REMOTE_PATH}"
  write_preferences
  install_launchers

  mapfile -t subjects < <(extract_subjects)
  : > "${MISSING_PDFS_FILE}"

  local downloaded_count=0
  local existing_count=0
  local missing_count=0
  local subject=""
  for subject in "${subjects[@]}"; do
    if [[ -f "${BOOKS_DIR}/${subject}.pdf" ]]; then
      existing_count=$((existing_count + 1))
    elif try_download_pdf "${subject}"; then
      downloaded_count=$((downloaded_count + 1))
    else
      printf '%s.pdf\n' "${subject}" >> "${MISSING_PDFS_FILE}"
      missing_count=$((missing_count + 1))
    fi
  done

  local section_text="${SECTION}"
  [[ -n "${section_text}" ]] || section_text="Genel"

  local finish_text="Kurulum tamamlandı.

Seçim: ${DEPARTMENT} / ${GRADE} / ${section_text}
Program klasörü: ${APP_DIR}
Kitap klasörü: ${BOOKS_DIR}
Masaüstü kısayolu: ${DESKTOP_DIR}/OpnDF.autostart

Hazır PDF: $((downloaded_count + existing_count))
Eksik PDF: ${missing_count}"

  if [[ "${missing_count}" -gt 0 ]]; then
    finish_text="${finish_text}

Eksik PDF listesi:
${MISSING_PDFS_FILE}"
  fi

  ui_info "${finish_text}"
}

main "$@"
