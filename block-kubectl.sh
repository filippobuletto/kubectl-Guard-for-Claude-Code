#!/bin/bash

# --- Mode switch (edit this line) ---------------------------------------------
# "deny": block non-allowlisted verbs outright (exit 2)
# "ask":  show a confirmation prompt for non-allowlisted verbs
# Hardcoded and readonly on purpose: it is not read from the environment,
# so the agent can't change it with `VERB_VIOLATION_MODE=ask kubectl ...`.
readonly VERB_VIOLATION_MODE="ask"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# --- Allowlists (edit to taste) ---------------------------------------------
ALLOWED_KUBECTL_VERBS="get describe top events explain api-resources api-versions version diff logs"
ALLOWED_HELM_VERBS="list ls status history version search template lint show"
BLOCKED_BINARIES="oc k9s kubectx kubens"

# Flags that change identity, endpoint or bypass RBAC/API semantics
DENIED_FLAGS='[[:space:]](--raw|--as|--as-group|--as-uid|--token|--kubeconfig|--server|-s|--context|--cluster|--user|--username|--password|--insecure-skip-tls-verify|--client-key|--client-certificate|--certificate-authority|--cache-dir|--kube-[a-z-]+|--post-renderer)([=[:space:]]|$)'

ASK_REASONS=""

# Hard block: always exits 2
deny() {
  echo "BLOCKED: '$COMMAND' $1. The user has prevented you from doing this." >&2
  exit 2
}

# Verb-level violation: behaviour depends on VERB_VIOLATION_MODE.
# In ask mode it only records the reason, so remaining segments are still
# scanned for hard denies (e.g. `kubectl delete x && kubectl get secret y`).
verb_violation() {
  if [[ "$VERB_VIOLATION_MODE" == "ask" ]]; then
    if [[ -z "$ASK_REASONS" ]]; then
      ASK_REASONS="$1"
    else
      ASK_REASONS="$ASK_REASONS; $1"
    fi
  else
    deny "$1"
  fi
}

emit_ask() {
  jq -n --arg reason "kubectl guard: '$COMMAND' $ASK_REASONS" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
}

# --- Direct API access without kubectl --------------------------------------
if echo "$COMMAND" | grep -qE '(curl|wget)' \
   && echo "$COMMAND" | grep -qE ':6443|kubernetes\.default|serviceaccount/token'; then
  deny "talks to the Kubernetes API directly"
fi

# --- Only inspect commands that involve k8s tooling -------------------------
if ! echo "$COMMAND" | grep -qE 'kubectl|kubecolor|helm|(^|[^[:alnum:]_-])(oc|k9s|kubectx|kubens)([^[:alnum:]_-]|$)'; then
  exit 0
fi

# --- Reject shell indirection we can't statically analyze -------------------
if echo "$COMMAND" | grep -qE '\$[A-Za-z_{(]|`|(^|[[:space:];&|])eval[[:space:]]|(ba|z|da)?sh[[:space:]]+-c'; then
  deny "uses shell indirection (variables, substitution, eval, sh -c) alongside k8s tooling"
fi

if echo "$COMMAND" | grep -qE 'KUBECONFIG=|KUBECTL_[A-Z_]+='; then
  deny "overrides kubectl environment"
fi

# --- Helpers ------------------------------------------------------------------
# Sets VERB (first non-flag token) and SUB (second non-flag token)
find_verb() {
  VERB=""; SUB=""
  local args=("$@") n=$# i=0 a
  while (( i < n )); do
    a="${args[$i]//[\"\']/}"
    case "$a" in
      -n|--namespace|-v|--v|--request-timeout|--profile) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) VERB="$a"; i=$((i+1)); break ;;
    esac
  done
  while (( i < n )); do
    a="${args[$i]//[\"\']/}"
    case "$a" in
      -n|--namespace) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) SUB="$a"; break ;;
    esac
  done
}

in_list() { [[ " $2 " == *" $1 "* ]]; }

check_kubectl() {
  local joined=" $* "
  echo "$joined" | grep -qE -- "$DENIED_FLAGS" && deny "uses a denied flag"

  find_verb "$@"
  [[ -z "$VERB" ]] && return 0   # bare `kubectl` just prints help

  case "$VERB" in
    auth)
      [[ "$SUB" == "can-i" || "$SUB" == "whoami" ]] || verb_violation "uses 'kubectl auth $SUB' (only can-i/whoami allowed)"
      ;;
    config)
      case "$SUB" in
        current-context|get-contexts) ;;
        view)
          echo "$joined" | grep -qE -- '[[:space:]]--flatten([=[:space:]]|$)' && deny "uses 'kubectl config view --flatten'"
          ;;
        *) verb_violation "uses 'kubectl config $SUB'" ;;
      esac
      ;;
    rollout)
      [[ "$SUB" == "status" ]] || verb_violation "uses 'kubectl rollout $SUB' (only status allowed)"
      ;;
    apply)
      local count
      count=$(echo "$joined" | grep -oE -- '--dry-run' | wc -l | tr -d ' ')
      if [[ "$count" != "1" ]] || ! echo "$joined" | grep -qE -- '--dry-run=(server|client)([[:space:]]|$)'; then
        verb_violation "uses 'kubectl apply' without a single explicit --dry-run=server|client"
      fi
      ;;
    *)
      in_list "$VERB" "$ALLOWED_KUBECTL_VERBS" || verb_violation "uses kubectl verb '$VERB', which is not on the allowlist"
      ;;
  esac

  # Secrets are never readable, even through allowed verbs (always a hard deny)
  if [[ "$VERB" == "get" || "$VERB" == "describe" || "$VERB" == "diff" ]]; then
    echo "$joined" | grep -qiE '(^|[[:space:],/])secrets?([[:space:],/]|$)' && deny "reads secrets"
  fi
  return 0
}

check_helm() {
  local joined=" $* "
  echo "$joined" | grep -qE -- "$DENIED_FLAGS" && deny "uses a denied flag"
  find_verb "$@"
  [[ -z "$VERB" ]] && return 0
  in_list "$VERB" "$ALLOWED_HELM_VERBS" || verb_violation "uses helm verb '$VERB', which is not on the allowlist"
  return 0
}

# --- Split into simple commands and validate each ----------------------------
while IFS= read -r segment; do
  read -ra tok <<< "$segment"
  for i in "${!tok[@]}"; do
    word="${tok[$i]//[\"\']/}"
    base="${word##*/}"
    rest=("${tok[@]:$((i+1))}")
    case "$base" in
      kubectl|kubectl.exe|kubecolor) check_kubectl "${rest[@]}" ;;
      helm|helm.exe)                 check_helm "${rest[@]}" ;;
      *)
        if in_list "$base" "$BLOCKED_BINARIES"; then
          deny "uses '$base', which is blocked"
        fi
        ;;
    esac
  done
done < <(echo "$COMMAND" | sed -E 's/(&&|\|\||[;|&])/\n/g')

# --- Final decision -------------------------------------------------------------
if [[ -n "$ASK_REASONS" ]]; then
  emit_ask
fi

exit 0
