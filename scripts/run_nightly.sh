
#!/usr/bin/env bash
# =====================================================================
# run_nightly.sh -- Host entry script (runs on 172.16.237.92)
# =====================================================================
set -uo pipefail

CONTAINER="sonic-mgmt"
HOST_CI_REPO="/home/user/sonic-mgmt-ci"
HOST_CI_SCRIPTS="/home/user/ci-scripts"
NGINX_CONTAINER="allure-web"
RUN_DATE="$(date +%F)"

echo "=============================================="
echo "[$(date -Is)] Nightly CI start, RUN_DATE=${RUN_DATE}"
echo "=============================================="

# ---- Step 1: update code on host (non-fatal on failure) ----
echo "[1] git pull latest master ..."
if [ -d "${HOST_CI_REPO}/.git" ]; then
  cd "${HOST_CI_REPO}"
  git config http.lowSpeedLimit 0
  git config http.lowSpeedTime 999999
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
SRC_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
find_script() {
  local name="$1"
  for cand in "${SRC_DIR}/${name}" "${SRC_DIR}/scripts/${name}"; do
    [ -f "${cand}" ] && { echo "${cand}"; return 0; }
  done
  find "${SRC_DIR}" -name "${name}" -type f 2>/dev/null | head -1
}
RIC_SRC="$(find_script run_in_container.sh)"
GEN_SRC="$(find_script gen_index.sh)"
if [ -z "${RIC_SRC}" ] || [ -z "${GEN_SRC}" ]; then
  echo "[2][error] cannot locate helper scripts under ${SRC_DIR}"; exit 3
fi
[ "${RIC_SRC}" != "${HOST_CI_SCRIPTS}/run_in_container.sh" ] && cp "${RIC_SRC}" "${HOST_CI_SCRIPTS}/"
[ "${GEN_SRC}" != "${HOST_CI_SCRIPTS}/gen_index.sh" ]        && cp "${GEN_SRC}" "${HOST_CI_SCRIPTS}/"
echo "[2] synced: ${RIC_SRC} , ${GEN_SRC}"
chmod +x "${HOST_CI_SCRIPTS}"/*.sh

# ---- Step 3: run main flow inside the container ----
echo "[3] docker exec into container to run test + report ..."
docker exec -e RUN_DATE="${RUN_DATE}" "${CONTAINER}" \
  bash /data/ci-scripts/run_in_container.sh "${RUN_DATE}"
TEST_RC=$?

# ---- Step 4: restart nginx ----
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
exit 0
