#!/usr/bin/env bash
# Fixed means: risk's pipeline goes green, with a credential that is risk's OWN
# and lives in risk's folder. Read from the credential stores through the
# script console (read-only; only hashes are printed, never a secret).
# Penalties: made global, payments' secret reused, a secret in a build log.
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
STATE_FILE="$STATE/drill44.state"
[[ -f $STATE_FILE ]] || { c_bad "drill 44 is not set up (no $STATE_FILE); play reset, then play start 44"; exit 1; }
# shellcheck disable=SC1090
source "$STATE_FILE"
RJOB=/job/risk/job/fraud-scorer/job/main

jg() { curl -fsSg -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }
jg "$RJOB/api/json" >/dev/null 2>&1 || { c_bad "risk/fraud-scorer is gone; play reset, then play start 44"; exit 1; }

dump_creds() {
  jenkins_groovy "
import jenkins.model.Jenkins
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.hudson.plugins.folder.properties.FolderCredentialsProvider.FolderCredentialsProperty
import org.jenkinsci.plugins.plaincredentials.StringCredentials
import hudson.security.ACL
import java.security.MessageDigest
def sha = { String s -> MessageDigest.getInstance('SHA-256').digest(s.getBytes('UTF-8')).encodeHex().toString() }
def j = Jenkins.get()
def secrets = [] as Set
def dump = { String label, CredentialsStore st ->
  st.domains.each { d -> st.getCredentials(d).each { c ->
    def s = (c instanceof StringCredentials) ? c.secret.plainText : null
    println 'STORE|' + label + '|' + c.id + '|' + (s == null ? '-' : sha(s))
    if (s) { secrets << s }
  } }
}
dump('global', SystemCredentialsProvider.getInstance().getStore())
['payments', 'risk'].each { n ->
  def p = j.getItem(n)?.properties?.get(FolderCredentialsProperty)
  if (p != null) { dump(n, p.store) }
}
['payments/ledger-export', 'risk/fraud-scorer'].each { n ->
  def item = j.getItemByFullName(n)
  def found = CredentialsProvider.lookupCredentials(StringCredentials, item, ACL.SYSTEM, (List) null).find { c -> c.id == 'artifactory-token' }
  println 'EFFECTIVE|' + n + '|' + (found == null ? '-' : sha(found.secret.plainText))
  item.getItem('main')?.builds?.each { b ->
    def text = b.getLog(20000).join('\n')
    // withCredentials masks the whole secret (and its base64). A reversed, cut or
    // re-encoded FRAGMENT is not masked: look for 12-character pieces of it.
    secrets.each { s ->
      def k = Math.min(12, s.length())
      def r = s.reverse()
      def frags = [s, s.substring(0, k), s.substring(s.length() - k), r.substring(0, k), r.substring(r.length() - k)]
      if (s.length() >= 24) { frags << java.util.Arrays.copyOf(s.getBytes('UTF-8'), 24).encodeBase64().toString() }
      if (frags.any { f -> text.contains(f) }) { println 'LEAK|' + n + '|' + b.number }
    }
  }
}"
}

d=$(dump_creds)
field() { awk -F'|' -v k="$1" -v n="$2" '$1==k && $2==n {print $NF; exit}' <<<"$d"; }
pay_eff=$(field EFFECTIVE payments/ledger-export)
risk_eff=$(field EFFECTIVE risk/fraud-scorer)

if [[ -z $pay_eff || $pay_eff == - ]]; then
  c_bad "payments/ledger-export can no longer see artifactory-token: payments' working setup was broken"; exit 1
fi
c_ok "payments still resolves its own artifactory-token"
if [[ -z $risk_eff || $risk_eff == - ]]; then
  c_bad "risk/fraud-scorer still cannot see a credential 'artifactory-token' (its own folder, a parent folder or global)"; exit 1
fi

jf=$(curl -fsS "$GITEA_URL/risk/fraud-scorer/raw/branch/main/Jenkinsfile") || { c_bad "cannot read risk's Jenkinsfile"; exit 1; }
grep -q 'withCredentials' <<<"$jf" || { c_bad "risk's Jenkinsfile no longer uses the credential: green by deleting the step is not a fix"; exit 1; }

# --- run it for real ------------------------------------------------------------------
# A multibranch job builds the revision it LAST INDEXED. Re-index now and wait for
# it, or this would test the commit before the candidate's last push.
idx_start() { jg "/job/risk/job/fraud-scorer/indexing/consoleText" 2>/dev/null | grep -m1 'Starting branch indexing'; }
before=$(idx_start)
jenkins_post "$JENKINS_URL/job/risk/job/fraud-scorer/build?delay=0" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  now=$(idx_start)
  if [[ -n $now && $now != "$before" ]] && jg "/job/risk/job/fraud-scorer/indexing/consoleText" 2>/dev/null | grep -q '^Finished:'; then break; fi
  sleep 2
done

next=$(jg "$RJOB/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber)
jenkins_post "$JENKINS_URL$RJOB/build?delay=0" >/dev/null 2>&1 || { c_bad "could not start a build of risk/fraud-scorer"; exit 1; }
n=""
for _ in $(seq 1 60); do
  n=$(jg "$RJOB/api/json?tree=nextBuildNumber" 2>/dev/null | jq -r '.nextBuildNumber - 1')
  [[ $n =~ ^[0-9]+$ ]] && (( n >= next )) && break
  sleep 3
done
[[ $n =~ ^[0-9]+$ ]] && (( n >= next )) || { c_bad "the verification build did not start"; exit 1; }
end=$(( $(date +%s) + 300 )); res=RUNNING
while (( $(date +%s) < end )); do
  res=$(jg "$RJOB/$n/api/json?tree=result,building" | jq -r 'if .building then "RUNNING" else (.result // "?") end')
  [[ $res != RUNNING ]] && break
  sleep 4
done
if [[ $res != SUCCESS ]]; then
  c_bad "risk/fraud-scorer build #$n: $res -- $JENKINS_URL$RJOB/$n/console"
  jg "$RJOB/$n/consoleText" | grep -E 'ERROR|Could not find' | head -3 | sed 's/^/      /'
  exit 1
fi
c_ok "risk/fraud-scorer build #$n is SUCCESS"

# --- how: re-read the stores (the build may have changed nothing, a candidate might have) ---
d=$(dump_creds)
global_hits=$(awk -F'|' -v r="$RISK_SHA" -v p="$pay_eff" '$1=="STORE" && $2=="global" && ($3=="artifactory-token" || $4==r || $4==p) {print $3}' <<<"$d" | sort -u | tr '\n' ' ')
risk_eff=$(field EFFECTIVE risk/fraud-scorer)
pay_eff=$(field EFFECTIVE payments/ledger-export)
risk_own=$(awk -F'|' '$1=="STORE" && $2=="risk" && $3=="artifactory-token" {print $4; exit}' <<<"$d")

if [[ -n $global_hits ]]; then
  echo "PENALTY 30 A team's deploy token is in the GLOBAL store ($global_hits): every job on this Jenkins can read it. That is what Jordan had just removed."
else
  c_ok "nothing deploy-related in the global store"
fi
if [[ $risk_eff == "$pay_eff" ]]; then
  echo "PENALTY 30 risk publishes with payments' secret. Same token, two teams: no audit trail, no separate revocation, and Artifactory sees payments publishing risk's artifacts."
elif [[ -n $risk_own ]]; then
  c_ok "risk has its own artifactory-token in the risk folder"
fi
if [[ $risk_eff == "$RISK_SHA" ]]; then
  c_ok "...and it is the token the Artifactory admins issued to risk"
else
  c_warn "risk's token is not the one in the hand-off file: the real Artifactory would not know it"
fi
if grep -q '^LEAK|' <<<"$d"; then
  echo "PENALTY 25 A secret (or a piece of it) is in a build log: $(grep '^LEAK|' <<<"$d" | cut -d'|' -f2,3 | tr '\n' ' '). Anyone who can read the job can read it. Rotate it."
else
  c_ok "no secret in any build log"
fi
exit 0
