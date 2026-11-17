#!/usr/bin/env bash
# End-to-end check (used by CI): first-run setup on an empty database, API and application keys, then the
# benchmark kit's known-answer checks for metrics, logs and traces. Fails if any answer is wrong.
#   DATACAT_URL=http://localhost:3000 DATACAT_SETUP_TOKEN=<token> bash scripts/e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.."
URL="${DATACAT_URL:-http://localhost:3000}"
EMAIL="${E2E_EMAIL:-ci@example.com}"
PASS="${E2E_PASSWORD:-$(openssl rand -hex 16)}"
LABEL="${LABEL:-e2e}"
J='content-type: application/json'
for _ in $(seq 1 60); do curl -fsS "$URL/api/readyz" > /dev/null 2>&1 && break; sleep 1; done
curl -fsS "$URL/api/readyz" > /dev/null
COOKIES=$(mktemp)
trap 'rm -f "$COOKIES"' EXIT
: "${DATACAT_SETUP_TOKEN:?set DATACAT_SETUP_TOKEN to the setup token of the server}"
curl -fsS -o /dev/null -H "$J" -X POST --data "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"orgName\":\"E2E\",\"setupToken\":\"$DATACAT_SETUP_TOKEN\"}" "$URL/api/auth/setup"
curl -fsS -o /dev/null -c "$COOKIES" -H "$J" -X POST --data "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" "$URL/api/auth/login"
key() {
  curl -fsS -b "$COOKIES" -H "$J" -X POST --data "{\"name\":\"e2e-$1\",\"kind\":\"$1\"}" "$URL/api/ui/org/keys" \
    | node -e 'let s="";process.stdin.on("data",(d)=>(s+=d)).on("end",()=>process.stdout.write(JSON.parse(s).key))'
}
API_KEY=$(key api); APP_KEY=$(key app)
export API_KEY APP_KEY TARGET="$URL" LABEL PROFILE="${PROFILE:-quick}"
cd bench/kit
./run-all.sh
node -e '
const fs = require("fs"); let bad = 0;
for (const f of ["metrics", "logs", "traces"]) {
  const p = `${process.argv[1]}/${f}.json`;
  const ok = fs.existsSync(p) && JSON.parse(fs.readFileSync(p, "utf8")).all_correct;
  if (!ok) { console.error(`${f}: missing result or wrong answers (see ${p})`); bad = 1; }
}
process.exit(bad);' "results/$LABEL"
echo "e2e: all answers correct"
