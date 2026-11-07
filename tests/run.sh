#!/usr/bin/env bash
# Behavior tests for scripts/block-kubectl.sh. Requires jq on PATH.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/block-kubectl.sh"
pass=0 fail=0

check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# decide <command> [mode...] -> allow | ask | deny
decide() {
  local out code
  out=$(jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" "${@:2}" 2>/dev/null)
  code=$?
  if [[ $code -eq 2 ]]; then echo deny
  elif [[ $code -eq 0 && -z "$out" ]]; then echo allow
  elif [[ $code -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == "ask" ]]; then echo ask
  else echo "unexpected(exit=$code out=$out)"; fi
}

# Read-only commands run freely
for c in 'kubectl get pods -n prod' 'kubectl logs web-0 -n prod --tail=100' \
         'kubectl -n prod rollout status deploy/web' 'kubectl config view' \
         'kubectl apply -f x.yaml --dry-run=server' 'helm list -A' 'ls -la'; do
  check "allow: $c" allow "$(decide "$c" ask)"
done

# Verb violations follow the mode
for c in 'kubectl -n prod delete pod x' 'kubectl rollout restart deploy/web' 'helm upgrade foo ./chart'; do
  check "ask mode asks: $c" ask "$(decide "$c" ask)"
  check "deny mode denies: $c" deny "$(decide "$c" deny)"
done

# Hard rules deny in both modes
for c in 'kubectl get secret db -o yaml' 'kubectl get pods --as admin' 'kubectl config view --raw' \
         'kubectl delete pod x && kubectl get secret y' 'kubectl get pods -n $NS' \
         'KUBECONFIG=/x kubectl get pods' 'curl -k https://kubernetes.default/api' 'k9s'; do
  check "hard deny (ask mode): $c" deny "$(decide "$c" ask)"
  check "hard deny (deny mode): $c" deny "$(decide "$c" deny)"
done

# Mode argument handling
check "no mode argument defaults to ask" ask "$(decide 'kubectl delete pod x')"
check "unknown mode fails closed" deny "$(decide 'kubectl delete pod x' bogus)"
check "unsubstituted placeholder fails closed" deny "$(decide 'kubectl delete pod x' '${user_config.verb_violation_mode}')"

# Ask reason names the command
reason=$(jq -nc '{tool_input: {command: "kubectl delete pod x"}}' | bash "$HOOK" ask | jq -r '.hookSpecificOutput.permissionDecisionReason')
check "ask reason mentions verb" true "$([[ "$reason" == *"'delete'"* ]] && echo true || echo false)"

# Plugin wiring passes the mode option to the script
hooks="$(dirname "$HOOK")/../hooks/hooks.json"
check "hooks.json passes mode option" '${user_config.verb_violation_mode}' "$(jq -r '.hooks.PreToolUse[0].hooks[0].args[1]' "$hooks" 2>/dev/null)"
check "hooks.json matches Bash" Bash "$(jq -r '.hooks.PreToolUse[0].matcher' "$hooks" 2>/dev/null)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
