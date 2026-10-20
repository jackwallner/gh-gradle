#!/bin/bash
# One phase of a gh-gradle run on the GitHub runner: gradle | collect.
# The app is checked out in ./app, and everything the caller gets back goes in
# ./out: summary.txt, status, build.log, test-results/ (JUnit XML), reports.zip
# (HTML test and lint reports) and, with products, products/ (APKs, AABs, AARs).
# Inputs arrive as environment variables from gradle.yml.
set -uo pipefail
set -f
W=$GITHUB_WORKSPACE OUT=$GITHUB_WORKSPACE/out
P=$W/app/${PROJECT_DIR:-android}
mkdir -p "$OUT"

note() { echo "gh-gradle: $*"; echo "$*" >> "$OUT/summary.txt"; }

do_gradle() {
  cd "$P" 2> /dev/null && [ -f gradlew ] || { note "FAILED: no gradlew in $PROJECT_DIR"; echo error > "$OUT/status"; exit 1; }
  chmod +x gradlew
  local t=$SECONDS rc
  # shellcheck disable=SC2086
  ./gradlew $TASKS --console=plain 2>&1 | tee "$OUT/build.log"
  rc=${PIPESTATUS[0]}
  echo "$rc" > "$OUT/gradle-rc"
  echo $((SECONDS - t)) > "$OUT/gradle-seconds"
  exit "$rc"
}

# Copies the files under every <module>/build/<sub> that match a find filter
# into $1, keeping their paths relative to the Gradle project.
gather() {
  local dest=$1 sub=$2; shift 2
  local list
  list=$(find . -path ./.gradle -prune -o -type f -path "*/build/$sub/*" "$@" -print 2> /dev/null)
  [ -n "$list" ] || return 1
  mkdir -p "$dest"
  printf '%s\n' "$list" | tar cf - -T - | tar xf - -C "$dest"
}

do_collect() {
  local rc secs
  rc=$(cat "$OUT/gradle-rc" 2> /dev/null || echo none)
  secs=$(cat "$OUT/gradle-seconds" 2> /dev/null || echo 0)
  { echo "repo: $REPO @ ${SHA:0:12} ($PROJECT_DIR)"
    echo "tasks: $TASKS${EMULATOR:+ (emulator API $EMULATOR)}"; } > "$OUT/summary.txt.new"
  [ -f "$OUT/summary.txt" ] && cat "$OUT/summary.txt" >> "$OUT/summary.txt.new"
  mv "$OUT/summary.txt.new" "$OUT/summary.txt"
  rm -f "$OUT/gradle-rc" "$OUT/gradle-seconds"
  if ! cd "$P" 2> /dev/null; then
    [ -f "$OUT/status" ] || echo error > "$OUT/status"
    note "FAILED: the snapshot has no $PROJECT_DIR folder"; return
  fi
  if [ "$rc" = none ]; then
    note "FAILED: Gradle never ran (setup failed, see the run log)"
    [ -f "$OUT/status" ] || echo error > "$OUT/status"
  fi

  # Unit test XML (build/test-results) and connected test XML (build/outputs/androidTest-results).
  gather "$OUT/test-results" test-results -name '*.xml' || true
  gather "$OUT/test-results" outputs/androidTest-results -name '*.xml' || true
  local reports
  reports=$(find . -path ./.gradle -prune -o -type d -path '*/build/reports' -print -prune 2> /dev/null)
  # shellcheck disable=SC2086
  [ -z "$reports" ] || zip -qr "$OUT/reports.zip" $reports

  if [ -d "$OUT/test-results" ]; then
    python3 - "$OUT/test-results" >> "$OUT/summary.txt" << 'PY'
import pathlib, sys, xml.etree.ElementTree as ET
tests = failed = skipped = 0
fails = []
for f in sorted(pathlib.Path(sys.argv[1]).rglob("*.xml")):
    try:
        root = ET.parse(f).getroot()
    except ET.ParseError:
        continue
    suites = [root] if root.tag == "testsuite" else root.iter("testsuite")
    for s in suites:
        for c in s.iter("testcase"):
            tests += 1
            bad = c.find("failure")
            if bad is None:
                bad = c.find("error")
            if bad is not None:
                failed += 1
                msg = (bad.get("message") or (bad.text or "")).strip().splitlines()
                fails.append(f"  FAIL {c.get('classname')}.{c.get('name')}: {(msg[0] if msg else '')[:300]}")
            elif c.find("skipped") is not None:
                skipped += 1
print(f"tests: {tests - failed - skipped} passed, {failed} failed, {skipped} skipped")
if fails:
    print("\n".join(fails[:30]))
PY
  else
    note "tests: no JUnit results"
  fi

  if [ "${PRODUCTS:-false}" = true ]; then
    if gather "$OUT/products" outputs \( -name '*.apk' -o -name '*.aab' -o -name '*.aar' -o -name output-metadata.json \); then
      note "products:"; (cd "$OUT/products" && find . -type f \( -name '*.apk' -o -name '*.aab' -o -name '*.aar' \) | sed 's#^\./#  #') >> "$OUT/summary.txt"
    else
      note "products: none (no APK, AAB or AAR under build/outputs)"
    fi
  fi

  if [ "$rc" = 0 ]; then
    echo passed > "$OUT/status"; note "PASSED in ${secs}s"
  elif [ "$rc" != none ]; then
    if grep -q 'There were failing tests' "$OUT/build.log" 2> /dev/null; then
      echo test-failed > "$OUT/status"
    else
      echo build-failed > "$OUT/status"
    fi
    note "FAILED ($(cat "$OUT/status"), Gradle exit $rc after ${secs}s):"
    { grep -E '^e: ' "$OUT/build.log" | sort -u | head -20
      awk '/^\* What went wrong:/{on=1} /^\* Try:/{on=0} on' "$OUT/build.log" | head -30; } >> "$OUT/summary.txt"
  fi
  cat "$OUT/summary.txt"
}

"do_$1"
