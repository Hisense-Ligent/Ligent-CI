#!/usr/bin/env bash
# =====================================================================
# gen_index.sh -- Scan the archive root and build the history index page
# Usage: bash gen_index.sh <archive_root_dir>
#   e.g. bash gen_index.sh /data/allure-report-archive
# =====================================================================
set -euo pipefail
ROOT="${1:?need archive root dir}"

{
  echo '<!DOCTYPE html>'
  echo '<html lang="en"><head><meta charset="utf-8">'
  echo '<title>SONiC-MGMT Nightly Test Reports</title>'
  echo '<style>'
  echo 'body{font-family:-apple-system,Segoe UI,sans-serif;margin:40px;background:#f5f6f8;color:#222}'
  echo 'h1{font-size:22px}'
  echo 'ul{list-style:none;padding:0;max-width:520px}'
  echo 'li{margin:8px 0;padding:12px 16px;background:#fff;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.08)}'
  echo 'a{text-decoration:none;color:#1666d4;font-size:16px}'
  echo 'a:hover{text-decoration:underline}'
  echo '.date{font-weight:600}'
  echo '.hint{color:#888;font-size:13px;margin-left:8px}'
  echo '</style>'
  echo '</head><body>'
  echo '<h1>SONiC-MGMT Nightly Test Reports</h1>'
  echo '<ul>'
  # list per-date report dirs in reverse order (latest first); skip history/
  FOUND=0
  for d in $(ls -1 "${ROOT}" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r); do
    echo "<li><a class=\"date\" href=\"./${d}/index.html\">Report ${d}</a></li>"
    FOUND=1
  done
  [ "$FOUND" = "0" ] && echo '<li class="hint">No reports yet</li>'
  echo '</ul>'
  echo "<p class=\"hint\">Last updated: $(date '+%Y-%m-%d %H:%M:%S %Z')</p>"
  echo '</body></html>'
} > "${ROOT}/index.html"

echo "index.html updated: ${ROOT}/index.html"

