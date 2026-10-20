#!/usr/bin/env bash
# =====================================================================
# run_nightly.sh -- Host entry script (runs on 172.16.237.92)
# Responsibilities:
#   1. git pull latest sonic-mgmt master on the host (host network is
#      stable; goes through the gh-proxy mirror)
#   2. sync container scripts into the bind-mount dir (/home/user = container /data)
#   3. docker exec into the container to run the main flow (test + report)
#   4. restart nginx so it re-binds the freshly generated report dir
# Usage:
#   bash run_nightly.sh
#   (Invoked by GitHub Actions; can also be run manually.)
# =====================================================================
set -uo pipefail

# ---- Constants ----
CONTAINER="sonic-mgmt"
HOST_CI_REPO="/home/user/sonic-mgmt-ci"          # host side == container /data/sonic-mgmt-ci
HOST_CI_SCRIPTS="/home/user/ci-scripts"          # script dir (container /data/ci-scripts)
NGINX_CONTAINER="allure-web"
RUN_DATE="$(date +%F)"                           # host local tz (Asia/Shanghai), e.g. 2026-09-04

echo "=============================================="
echo "[$(date -Is)] Nightly CI start, RUN_DATE=${RUN_DATE}"
echo "=============================================="

# ---- Step 1: update code on host (non-fatal on failure, fall back to existing code) ----
echo "[1] git pull latest master ..."
if [ -d "${HOST_CI_REPO}/.git" ]; then
  cd "${HOST_CI_REPO}"
  git config http.lowSpeedLimit 0
  git config http.lowSpeedTime 999999
  # Restore files that run_in_container.sh overwrites/patches every run. They are
  # git-tracked, so leaving them modified can make 'pull --ff-only' fail and the
  # run would silently continue on stale code. They are re-applied in Step 1.
  git checkout -- ansible/lab ansible/testbed.yaml \
    ansible/files/sonic_lab_devices.csv ansible/files/sonic_lab_links.csv \
    ansible/module_utils/port_utils.py 2>/dev/null || true
  if git pull --ff-only origin master; then
    echo "[1] git pull OK, code updated to latest master"
  else
    echo "[1][warn] git pull failed, continue with existing code (non-fatal)"
  fi
else
  echo "[1][warn] ${HOST_CI_REPO} is not a git repo, skip pull, use existing code"
fi

# ---- Step 2: sync container scripts into bind-mount dir ----
echo "[2] sync container scripts to ${HOST_CI_SCRIPTS} ..."
mkdir -p "${HOST_CI_SCRIPTS}"
# GITHUB_WORKSPACE is the checked-out repo path under GHA; fall back to script dir for manual runs
SRC_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
# Locate the two helper scripts wherever they live in the repo: they may sit at
# the repo root (next to run_nightly.sh) or under a scripts/ subdir. Search both.
find_script() {
  local name="$1"
  for cand in "${SRC_DIR}/${name}" "${SRC_DIR}/scripts/${name}"; do
    [ -f "${cand}" ] && { echo "${cand}"; return 0; }
  done
  # last resort: search the whole checkout
  find "${SRC_DIR}" -name "${name}" -type f 2>/dev/null | head -1
}
RIC_SRC="$(find_script run_in_container.sh)"
GEN_SRC="$(find_script gen_index.sh)"
if [ -z "${RIC_SRC}" ] || [ -z "${GEN_SRC}" ]; then
  echo "[2][error] cannot locate helper scripts under ${SRC_DIR}"; exit 3
fi
# copy only if source differs from destination (avoids same-file error on manual runs)
[ "${RIC_SRC}" != "${HOST_CI_SCRIPTS}/run_in_container.sh" ] && cp "${RIC_SRC}" "${HOST_CI_SCRIPTS}/"
[ "${GEN_SRC}" != "${HOST_CI_SCRIPTS}/gen_index.sh" ]        && cp "${GEN_SRC}" "${HOST_CI_SCRIPTS}/"
echo "[2] synced: ${RIC_SRC} , ${GEN_SRC}"
chmod +x "${HOST_CI_SCRIPTS}"/*.sh

# ---- Step 3: run main flow inside the container ----
echo "[3] docker exec into container to run test + report ..."
docker exec -e RUN_DATE="${RUN_DATE}" "${CONTAINER}" \
  bash /data/ci-scripts/run_in_container.sh "${RUN_DATE}"
TEST_RC=$?

# ---- Step 4: restart nginx (important) ----
# 'allure generate --clean' recreates the report dir, changing its inode.
# The old inode bound by nginx becomes stale and returns 404, so nginx
# must be restarted to re-bind the current directory.
echo "[4] restart nginx to re-bind the latest report ..."
docker restart "${NGINX_CONTAINER}" >/dev/null 2>&1 \
  && echo "[4] nginx restarted" \
  || echo "[4][warn] nginx restart failed, please check manually"

echo "=============================================="
echo "[$(date -Is)] Nightly CI finished, test_rc=${TEST_RC}"
echo "Report portal : http://172.16.237.92:8081/"
echo "Today's report: http://172.16.237.92:8081/${RUN_DATE}/"
echo "=============================================="

# Job success no longer depends on test cases; always exit 0.
# Individual case results are reviewed in the Allure report, not the job status.
exit 0
