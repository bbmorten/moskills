#!/usr/bin/env bash
# api-reachability.sh — can a browser-based lab cell call this API?
#
# A course that runs Python in the browser (Pyodide) can only reach hosts that
# send CORS headers. On-prem systems never do. This probe answers the question
# in seconds, instead of after a course is written and every lab fails with an
# opaque network error.
#
#   api-reachability.sh https://webexapis.com/v1/people/me
#   api-reachability.sh --origin https://collab-automation.elearn.morten.com.tr URL...
#
# Exit: 0 all reachable · 1 at least one not · 2 usage error.

set -uo pipefail

# Probe as the DEPLOYED course, not as your dev server. Measured against
# webexapis.com on 2026-08-17: it answers an https origin (ports, bare IPs and
# .local names all fine) but rejects the literal hostname `localhost` and every
# http:// origin with a 401 and no ACAO header. Probing from localhost would
# therefore report "unreachable" for an API that works perfectly in production.
ORIGIN="https://course.example.com"
HDRS="authorization,content-type"
usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin) ORIGIN="${2:?--origin needs a value}"; shift 2 ;;
    --headers) HDRS="${2:?--headers needs a value}"; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage 2 ;;
    *) break ;;
  esac
done

[[ $# -gt 0 ]] || usage 2

case "$ORIGIN" in
  http://*)
    echo "⚠️  --origin is http://. Many APIs (Webex among them) refuse CORS for"
    echo "    non-HTTPS origins, so this probe will under-report. Use the course's"
    echo "    real https:// origin."; echo ;;
esac
case "$ORIGIN" in
  *localhost*)
    echo "⚠️  --origin contains 'localhost', which some APIs (Webex among them)"
    echo "    reject outright. Probe with the deployed course origin instead."; echo ;;
esac

rc=0
for url in "$@"; do
  host="${url#*://}"; host="${host%%/*}"
  echo "── $url"

  pre=$(curl -s -i -X OPTIONS "$url" \
          -H "Origin: $ORIGIN" \
          -H "Access-Control-Request-Method: GET" \
          -H "Access-Control-Request-Headers: $HDRS" \
          --max-time 20 2>/dev/null)
  pre_status=$(printf '%s' "$pre" | awk 'NR==1{print $2}')

  # Header names are case-insensitive; HTTP/2 lowercases them.
  allow_origin=$(printf '%s' "$pre" | grep -i '^access-control-allow-origin:' | head -1 | cut -d' ' -f2- | tr -d '\r')
  allow_hdrs=$(printf '%s'  "$pre" | grep -i '^access-control-allow-headers:' | head -1 | cut -d' ' -f2- | tr -d '\r')
  allow_meth=$(printf '%s'  "$pre" | grep -i '^access-control-allow-methods:' | head -1 | cut -d' ' -f2- | tr -d '\r')

  # A simple request too: some APIs skip preflight but still send ACAO, and the
  # error body being readable is what lets learners see real error text.
  simple=$(curl -s -i "$url" -H "Origin: $ORIGIN" --max-time 20 2>/dev/null)
  simple_status=$(printf '%s' "$simple" | awk 'NR==1{print $2}')
  simple_acao=$(printf '%s' "$simple" | grep -i '^access-control-allow-origin:' | head -1 | cut -d' ' -f2- | tr -d '\r')

  echo "   preflight        : ${pre_status:-no response}"
  echo "   allow-origin     : ${allow_origin:-<none>}"
  echo "   allow-methods    : ${allow_meth:-<none>}"
  echo "   allow-headers    : ${allow_hdrs:-<none>}"
  echo "   simple request   : ${simple_status:-no response} (ACAO: ${simple_acao:-<none>})"

  if [[ -z "$allow_origin" && -z "$simple_acao" ]]; then
    echo "   ❌ NOT reachable from a browser cell — no CORS headers."
    echo "      → fixture-backed Track A lab; real only in Track B (local Jupyter)."
    rc=1
  elif [[ "$allow_hdrs" != *[Aa]uthorization* && -n "$allow_origin" ]]; then
    echo "   ⚠️  CORS present but 'authorization' is not in allow-headers."
    echo "      → unauthenticated calls may work; token-bearing ones will not. Verify by hand."
    rc=1
  else
    echo "   ✅ Reachable. Add to the course CSP:"
    echo "      connect-src 'self' \${PLATFORM} https://${host}"
  fi
  echo
done

if [[ $rc -eq 0 ]]; then
  echo "All targets reachable from a browser lab cell."
else
  echo "At least one target needs a fixture-backed (Track A) lab. See the"
  echo "two-track model in ~/.claude/skills/course-precontent/SKILL.md §5."
fi
exit $rc
