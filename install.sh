#!/usr/bin/env bash
set -Eeuo pipefail

REPO_OWNER="${OPNDF_REPO_OWNER:-araswqm}"
REPO_NAME="${OPNDF_REPO_NAME:-OpnDF}"
REPO_BRANCH="${OPNDF_REPO_BRANCH:-main}"
RAW_BASE="${OPNDF_RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LOCAL_INSTALLER="${SCRIPT_DIR}/Scripts/install.sh"

if [[ "${OPNDF_USE_LOCAL_INSTALLER:-}" == "1" && -s "${LOCAL_INSTALLER}" ]]; then
  exec bash "${LOCAL_INSTALLER}" "$@"
fi

TMP_INSTALLER="$(mktemp -t opndf-install.XXXXXX.sh)"
cleanup() {
  rm -f "${TMP_INSTALLER}"
}
trap cleanup EXIT

INSTALLER_URL="${RAW_BASE%/}/Scripts/install.sh"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${INSTALLER_URL}" -o "${TMP_INSTALLER}"
elif command -v wget >/dev/null 2>&1; then
  wget -q "${INSTALLER_URL}" -O "${TMP_INSTALLER}"
else
  printf 'OpnDF kurulumu icin curl veya wget gerekli.\n' >&2
  exit 1
fi

exec bash "${TMP_INSTALLER}" "$@"
