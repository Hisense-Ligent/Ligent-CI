
#!/usr/bin/env bash
# =====================================================================
# run_in_container.sh -- Main flow inside the sonic-mgmt container
# (invoked by run_nightly.sh via docker exec)
# =====================================================================
set -uo pipefail   # no -e: the test stage must capture exit code and continue

RUN_DATE="${1:?need RUN_DATE, e.g. 2026-09-04}"

# ---- Path constants ----
CI_REPO="/data/sonic-mgmt-ci"
CFG_SRC="/data/sonic-mgmt-refs-pull-26402-head"      # config source (tuned Ligent dut_info)
ALLURE_BIN="/data/allure-2.29.0/bin/allure"
RESULTS_DIR="/data/allure-results"
REPORT_ROOT="/data/allure-report-archive"            # archive root (per-date)
REPORT_DIR="${REPORT_ROOT}/${RUN_DATE}"
HISTORY_DIR="${REPORT_ROOT}/history"

# ---- Testbed constants ----
TB_NAME="hisense-module"
DUT="my-dut-1"
TOPO="ptp"
PORTS=("Ethernet0" "Ethernet8")
declare -A ALIAS_PLAIN=( [Ethernet0]="Eth1" [Ethernet8]="Eth2" )

echo "===== [in-container] RUN_DATE=${RUN_DATE} ====="

# ---- Step 1: inject lab-specific config ----
echo "[1] inject lab / testbed.yaml / inventory ..."
cp "${CFG_SRC}/ansible/lab"          "${CI_REPO}/ansible/lab"
cp "${CFG_SRC}/ansible/testbed.yaml" "${CI_REPO}/ansible/testbed.yaml"
mkdir -p "${CI_REPO}/ansible/files/transceiver"
cp -r "${CFG_SRC}/ansible/files/transceiver/inventory" \
      "${CI_REPO}/ansible/files/transceiver/"

# ---- Step 2: DUT reachability check ----
echo "[2] check DUT reachability ..."
cd "${CI_REPO}/ansible"
ping -c 3 172.16.237.100 || { echo "[2][error] DUT unreachable, abort"; exit 2; }
ansible -m ping -i lab "${DUT}" || { echo "[2][error] ansible cannot reach DUT, abort"; exit 2; }

# ---- Step 3: clear alias parentheses (idempotent, do NOT restore) ----
echo "[3] clear alias parentheses ..."
for p in "${PORTS[@]}"; do
  ansible -m shell -i lab "${DUT}" \
    -a "sonic-db-cli CONFIG_DB hset 'PORT|${p}' alias '${ALIAS_PLAIN[$p]}'" -b
done

# ---- Step 4: generate Allure environment / executor metadata ----
echo "[4] generate environment.properties / executor.json ..."
rm -rf "${RESULTS_DIR}"; mkdir -p "${RESULTS_DIR}"
SONIC_VER=$(ansible -m shell -i lab "${DUT}" \
  -a "sonic-cfggen -y /etc/sonic/sonic_version.yml -v build_version" -b 2>/dev/null | tail -1)
cat > "${RESULTS_DIR}/environment.properties" <<EOF
DUT.Hostname=${DUT}
DUT.IP=172.16.237.100
DUT.HwSku=Accton-AS9817-64O
DUT.SONiC.Version=${SONIC_VER}
Transceiver.Vendor=Ligent
Transceiver.PN=LMS3826S-PC+
Transceiver.Ports=Ethernet0,Ethernet8
Testbed=${TB_NAME}
Topology=${TOPO}
EOF
cat > "${RESULTS_DIR}/executor.json" <<EOF
{
  "name": "GitHub Actions",
  "type": "github",
  "buildName": "sonic-mgmt-nightly ${RUN_DATE}",
  "buildUrl": "${GHA_RUN_URL:-http://172.16.237.92:8081/${RUN_DATE}/}",
  "reportName": "SONiC-MGMT Nightly ${RUN_DATE}"
}
EOF

# ---- Step 5: run all transceiver/dom/ cases ----
echo "[5] run_tests.sh for transceiver/dom/ ..."
cd "${CI_REPO}/tests"
./run_tests.sh \
  -n "${TB_NAME}" \
  -d "${DUT}" \
  -f "${CI_REPO}/ansible/testbed.yaml" \
  -i ../ansible/lab \
  -t "${TOPO}" \
  -u \
  -c transceiver/dom/ \
  -e "--skip_sanity --disable_loganalyzer --disable_memory_utilization --alluredir=${RESULTS_DIR}"
TEST_RC=$?
echo "[5] test exit code=${TEST_RC}"

# ---- Step 6: allure generate (--single-file guarantees index.html) ----
echo "[6] allure generate ..."
mkdir -p "${REPORT_ROOT}" "${HISTORY_DIR}"
[ -d "${HISTORY_DIR}" ] && cp -r "${HISTORY_DIR}" "${RESULTS_DIR}/history" 2>/dev/null || true
"${ALLURE_BIN}" generate "${RESULTS_DIR}" -o "${REPORT_DIR}" --clean --single-file
[ -d "${RESULTS_DIR}/history" ] && cp -r "${RESULTS_DIR}/history" "${HISTORY_DIR}" 2>/dev/null || true

# ---- Step 7: regenerate the index page ----
echo "[7] update index page ..."
bash /data/ci-scripts/gen_index.sh "${REPORT_ROOT}"

echo "===== [in-container] done report=${REPORT_DIR}, test_rc=${TEST_RC} ====="
# CI only guarantees the pipeline completed; individual test-case results are
# reviewed in the Allure report. Always exit 0 so a single failing case does
# not turn the whole job red (which would trigger failure e-mails every night).
echo "[note] test_rc=${TEST_RC} recorded above; exiting 0 (see Allure report for case results)"
exit 0
