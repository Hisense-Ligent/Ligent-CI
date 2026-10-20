#!/usr/bin/env bash
# =====================================================================
# run_in_container.sh -- Main flow inside the sonic-mgmt container
# (invoked by run_nightly.sh via docker exec)
# Does NOT touch the github network (code already pulled on host):
#   1. inject lab-specific config (lab / testbed.yaml / transceiver inventory)
#   2. DUT reachability check
#   3. clear alias parentheses (idempotent; decision A: do NOT restore)
#   4. generate environment.properties / executor.json for Allure
#   5. run all transceiver/dom/ test cases
#   6. allure generate --single-file (guarantees index.html)
#   7. archive under a per-date dir + regenerate the index page
# Usage: bash run_in_container.sh <RUN_DATE>
# =====================================================================
set -uo pipefail   # no -e: the test stage must capture exit code and continue

RUN_DATE="${1:?need RUN_DATE, e.g. 2026-09-04}"

# ---- Quiet down ansible's cosmetic warnings for cleaner CI logs ----
# These are harmless: an unrecognized 'ptf' inventory key and the Python
# interpreter auto-discovery notice. Pin the interpreter and silence the
# system/localhost/deprecation notices so the log stays readable.
export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_SYSTEM_WARNINGS=False
export ANSIBLE_DEPRECATION_WARNINGS=False
export ANSIBLE_ACTION_WARNINGS=False
export ANSIBLE_LOCALHOST_WARNING=False
export PYTHONWARNINGS=ignore

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
PORTS=("Ethernet0" "Ethernet8" "Ethernet96" "Ethernet104" "Ethernet176" "Ethernet184")
declare -A ALIAS_PLAIN=(
  [Ethernet0]="Eth1"    [Ethernet8]="Eth2"
  [Ethernet96]="Eth13"  [Ethernet104]="Eth14"
  [Ethernet176]="Eth23" [Ethernet184]="Eth24"
)

echo "===== [in-container] RUN_DATE=${RUN_DATE} ====="

# ---- Step 1: inject lab-specific config ----
echo "[1] inject lab / testbed.yaml / graph files / inventory ..."
cp "${CFG_SRC}/ansible/lab"          "${CI_REPO}/ansible/lab"
cp "${CFG_SRC}/ansible/testbed.yaml" "${CI_REPO}/ansible/testbed.yaml"
mkdir -p "${CI_REPO}/ansible/files/transceiver"
cp -r "${CFG_SRC}/ansible/files/transceiver/inventory" \
      "${CI_REPO}/ansible/files/transceiver/"

# Connection graph (needed since upstream #28393 added the port_peers fixture to
# CDB tests). conn_graph_facts group=lab reads these two files; upstream ships
# them with sample devices only, so inject ours (my-dut-1 + 3 loopback pairs).
for f in sonic_lab_devices.csv sonic_lab_links.csv; do
  cp "${CFG_SRC}/ansible/files/${f}" "${CI_REPO}/ansible/files/${f}" \
    || { echo "[1][error] missing ${CFG_SRC}/ansible/files/${f}, abort"; exit 2; }
done

# Upstream port_utils.py has no Accton-AS9817-64O entry and falls back to a
# generic 32-port map (Ethernet0..124), rejecting Ethernet176/184. Add the real
# map: 64x800G (Eth1..Eth64 -> Ethernet0..504, step 8) + 2x25G mgmt ports.
# Idempotent; run_nightly.sh restores the file before each git pull.
# TODO: remove once the hwsku is merged upstream.
PORT_UTILS="${CI_REPO}/ansible/module_utils/port_utils.py"
if ! grep -q 'Accton-AS9817-64O' "${PORT_UTILS}"; then
  python3 - "${PORT_UTILS}" <<'PYEOF' || exit 2
import sys
path = sys.argv[1]
anchor = '        elif hwsku == "Accton-AS7712-32X":\n'
patch = (
    '        elif hwsku == "Accton-AS9817-64O":\n'
    '            for i in range(1, 65):\n'
    '                port_alias_to_name_map["Eth%d" % i] = "Ethernet%d" % ((i - 1) * 8)\n'
    '            port_alias_to_name_map["Eth65"] = "Ethernet512"\n'
    '            port_alias_to_name_map["Eth66"] = "Ethernet513"\n'
)
src = open(path).read()
if anchor not in src:
    sys.exit("[1][error] port_utils.py anchor not found, patch needs update")
open(path, "w").write(src.replace(anchor, patch + anchor, 1))
PYEOF
  echo "[1] patched port_utils.py for Accton-AS9817-64O"
fi

# Fail fast: verify the graph resolves before running any test, instead of
# producing a screen of setup ERRORs.
( cd "${CI_REPO}/ansible" && ansible localhost -m conn_graph_facts -M library \
    -a "filepath=${CI_REPO}/ansible/files/ group=lab hosts=${DUT}" >/dev/null 2>&1 ) \
  || { echo "[1][error] conn_graph_facts cannot resolve ${DUT}, abort"; exit 2; }
echo "[1] connection graph OK for ${DUT}"

# ---- Step 2: DUT reachability check ----
echo "[2] check DUT reachability ..."
cd "${CI_REPO}/ansible"
ping -c 3 172.16.237.100 || { echo "[2][error] DUT unreachable, abort"; exit 2; }
ansible -m ping -i lab "${DUT}" || { echo "[2][error] ansible cannot reach DUT, abort"; exit 2; }

# ---- Step 3: clear alias parentheses (idempotent, do NOT restore) ----
# Workaround for show_interface.py regex not accepting parenthesized alias
# (e.g. Eth1(Port1)). Runtime-only change (no 'config save'); a DUT reboot
# restores the original alias, hence we re-apply every run.
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
# buildOrder must be a monotonically increasing integer so Allure can order the
# trend points and label them per run; derive it from the date (YYYYMMDD).
BUILD_ORDER="$(echo "${RUN_DATE}" | tr -d '-')"
cat > "${RESULTS_DIR}/executor.json" <<EOF
{
  "name": "GitHub Actions",
  "type": "github",
  "buildOrder": ${BUILD_ORDER},
  "buildName": "Nightly ${RUN_DATE}",
  "buildUrl": "http://172.16.237.92:8081/${RUN_DATE}/",
  "reportUrl": "http://172.16.237.92:8081/${RUN_DATE}/",
  "reportName": "SONiC-MGMT Nightly ${RUN_DATE}"
}
EOF

# ---- Step 5: run all transceiver/dom/ cases ----
# TEST_SCOPE: run the whole transceiver suite, but EXCLUDE two risky subsets
# for unattended nightly runs:
#   - cdb_firmware_upgrade/ : actually flashes module firmware (can brick a module)
#   - oir/                  : online insertion/removal (may need manual/rig action)
# Read-only checks (dom / eeprom / attribute_parser / system) are safe to run.
# =====================================================================
# DESTRUCTIVE TEST SWITCH  --  set to 1 later to enable reboot/restart tests
#   0 = safe mode: only read-only checks run (no DUT reboot/restart at all)
#   1 = full mode: also run reboot / config-reload / daemon-restart / reset
# NOTE: cold reboot / config reload / swss restart have NO per-attribute gate
#       in the test code, so the ONLY way to keep them off is this switch.
#       When you are ready to allow DUT-disrupting tests, change 0 -> 1 here.
# =====================================================================
RUN_DESTRUCTIVE=0

TEST_SCOPE="transceiver/"
# firmware upgrade (flashes module) and oir (needs a physical rig) are ALWAYS
# excluded regardless of the switch.
EXTRA_IGNORE="--ignore=transceiver/cdb_firmware_upgrade --ignore=transceiver/oir"
if [ "${RUN_DESTRUCTIVE}" != "1" ]; then
  # safe mode: also skip everything that reboots/restarts the DUT
  EXTRA_IGNORE="${EXTRA_IGNORE} --ignore=transceiver/eeprom/test_eeprom_scenario.py --ignore=transceiver/system"
  echo "[5] run_tests.sh for ${TEST_SCOPE} (SAFE mode: read-only only) ..."
else
  echo "[5] run_tests.sh for ${TEST_SCOPE} (FULL mode: destructive tests ENABLED) ..."
fi
cd "${CI_REPO}/tests"
./run_tests.sh \
  -n "${TB_NAME}" \
  -d "${DUT}" \
  -f "${CI_REPO}/ansible/testbed.yaml" \
  -i ../ansible/lab \
  -t "${TOPO}" \
  -u \
  -c "${TEST_SCOPE}" \
  -e "--skip_sanity --disable_loganalyzer --disable_memory_utilization -p no:warnings ${EXTRA_IGNORE} --alluredir=${RESULTS_DIR}"
TEST_RC=$?
echo "[5] test exit code=${TEST_RC}"

# ---- Step 5b: CDB firmware tests (all cases, Ethernet96 / LMS3821S-PC5) ----
# Positive cases really flash the module. The package-scoped fixture
# restore_original_firmware_baseline restores active=gold / inactive=original
# before and after the package.
# Prerequisites (not managed here):
#   - 3 bins pre-staged on DUT under /host/cmis_cdb_firmware/
#   - manifest + cdb_firmware_upgrade.json in ${CFG_SRC} inventory (copied in Step 1)
RUN_CDB=1
CDB_PORTS=("Ethernet96")
if [ "${RUN_CDB}" = "1" ]; then
  echo "[5b] enable dom_polling on CDB ports (CDB fixture needs it enabled first) ..."
  cd "${CI_REPO}/ansible"
  for p in "${CDB_PORTS[@]}"; do
    ansible -m shell -i lab "${DUT}" \
      -a "sonic-db-cli CONFIG_DB hset 'PORT|${p}' dom_polling enabled" -b
  done
  sleep 60   # let xcvrd complete one DOM polling cycle
  echo "[5b] run all CDB firmware cases ..."
  cd "${CI_REPO}/tests"
  ./run_tests.sh \
    -n "${TB_NAME}" \
    -d "${DUT}" \
    -f "${CI_REPO}/ansible/testbed.yaml" \
    -i ../ansible/lab \
    -t "${TOPO}" \
    -u \
    -c "transceiver/cdb_firmware_upgrade/" \
    -e "--skip_sanity --disable_loganalyzer --disable_memory_utilization -p no:warnings --alluredir=${RESULTS_DIR}"
  CDB_RC=$?
  echo "[5b] CDB test exit code=${CDB_RC}"
  # Log module firmware state after the package so a broken restore is visible
  # in the CI log. Baseline: Active 1.0.0 / Inactive 255.0.0.
  echo "[5b] post-run firmware state of CDB ports (expect Active 1.0.0 / Inactive 255.0.0) ..."
  cd "${CI_REPO}/ansible"
  for p in "${CDB_PORTS[@]}"; do
    ansible -m shell -i lab "${DUT}" -a "sfputil show fwversion ${p}" -b
  done
fi

# ---- Step 6: allure generate ----
# NOTE: do NOT use --single-file here. The single-file report does not emit the
# history/*.json files Allure needs to render the Trend widget across runs.
# A normal (multi-file) report keeps history under <report>/history and lets the
# Trend chart accumulate over time.
echo "[6] allure generate ..."
mkdir -p "${REPORT_ROOT}"
# feed previous history into this run so the trend line stays continuous.
# copy CONTENTS (history/.) into results/history to avoid nesting history/history/...
rm -rf "${RESULTS_DIR}/history"
if [ -d "${HISTORY_DIR}" ] && [ -n "$(ls -A "${HISTORY_DIR}" 2>/dev/null)" ]; then
  mkdir -p "${RESULTS_DIR}/history"
  cp -r "${HISTORY_DIR}/." "${RESULTS_DIR}/history/"
fi
"${ALLURE_BIN}" generate "${RESULTS_DIR}" -o "${REPORT_DIR}" --clean
# persist THIS run's history (produced under the report dir) for the next run
rm -rf "${HISTORY_DIR}"; mkdir -p "${HISTORY_DIR}"
if [ -d "${REPORT_DIR}/history" ]; then
  cp -r "${REPORT_DIR}/history/." "${HISTORY_DIR}/"
fi

# ---- Step 7: regenerate the index page ----
echo "[7] update index page ..."
bash /data/ci-scripts/gen_index.sh "${REPORT_ROOT}"

# Note (decision A): alias stays cleared, not restored; runtime-only change,
# never persisted, so a DUT reboot restores the original value automatically.
# nginx restart is handled by the host-side run_nightly.sh (no docker control here).

echo "===== [in-container] done report=${REPORT_DIR}, test_rc=${TEST_RC} ====="
# CI only guarantees the pipeline completed; individual test-case results are
# reviewed in the Allure report. Always exit 0 so a single failing case does
# not turn the whole job red (which would trigger failure e-mails every night).
echo "[note] test_rc=${TEST_RC} recorded above; exiting 0 (see Allure report for case results)"
exit 0
