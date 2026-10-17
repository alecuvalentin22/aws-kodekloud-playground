# shellcheck shell=bash
# Helpers for drill 46 only (sourced after lib/common.sh).
BRANCH=feature/refund-endpoint
BRANCH_ENC=feature%2Frefund-endpoint

# Every item in Jenkins that is not demo-api's own branch jobs, one full name per line.
items_outside_demo_api() {
  jenkins_groovy 'import jenkins.model.*
Jenkins.get().allItems.each { println it.fullName }
null' | grep -vE '^(Result:|demo-api(/|$))' | sort || true
}
