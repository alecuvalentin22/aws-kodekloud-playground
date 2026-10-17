#!/usr/bin/env bash
# Run the invoice tests against vendor/ and write a JUnit report to build/reports/.
# (Simulated: three checks, one of which needs the money-lib version in deps.lock.)
set -uo pipefail
want=$(sed -n 's/^money-lib=//p' deps.lock)
have=$(cat vendor/money-lib/VERSION 2>/dev/null || echo none)
echo "money-lib: have $have, deps.lock wants $want"

mkdir -p build/reports
failures=0
cases=""
record() {   # record NAME PASS(0/1) [message]
  if [[ $2 == 1 ]]; then
    cases+="  <testcase classname=\"invoice\" name=\"$1\"/>"$'\n'
    echo "  PASS $1"
  else
    cases+="  <testcase classname=\"invoice\" name=\"$1\"><failure message=\"$3\"/></testcase>"$'\n'
    echo "  FAIL $1: $3"
    failures=$((failures + 1))
  fi
}
record test_line_total 1
if [[ $(printf '%s\n%s\n' "$have" "$want" | sort -V | head -1) == "$want" ]]; then
  record test_half_cent_rounding 1
else
  record test_half_cent_rounding 0 "money-lib $have is older than deps.lock wants ($want)"
fi
[[ -f templates/invoice.tmpl ]] && record test_template_present 1 || record test_template_present 0 "templates/invoice.tmpl missing"

printf '<testsuite name="invoice-gen" tests="3" failures="%s">\n%s</testsuite>\n' "$failures" "$cases" > build/reports/TEST-invoice-gen.xml
exit $(( failures > 0 ))
