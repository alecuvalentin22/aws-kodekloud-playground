#!/usr/bin/env bash
# The baseline has no approvals at all; put it back to that.
source "$(dirname "$0")/../../lib/common.sh"; load_creds
jenkins_groovy 'org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get().clearApprovedSignatures(); println "cleared"'
