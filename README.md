<div align="center">

# kubectl Guard for Claude Code

A Claude Code plugin that restricts what an AI agent can do with `kubectl` and `helm` through the Bash tool. It uses an **allowlist**: only known read-only operations run freely, everything else is either blocked or sent to you for confirmation.

[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffilippobuletto%2Fkubectl-Guard-for-Claude-Code%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version)](.claude-plugin/plugin.json)
[![License](https://img.shields.io/github/license/filippobuletto/kubectl-Guard-for-Claude-Code)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/filippobuletto/kubectl-Guard-for-Claude-Code)](https://github.com/filippobuletto/kubectl-Guard-for-Claude-Code/commits/main)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-D97757?logo=claude&logoColor=white)](https://code.claude.com/docs/en/plugins)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-kubectl-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/docs/reference/kubectl/)
[![Helm](https://img.shields.io/badge/Helm-guarded-0F1689?logo=helm&logoColor=white)](https://helm.sh/)
[![Bash](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](scripts/block-kubectl.sh)
[![jq](https://img.shields.io/badge/requires-jq-blue)](https://jqlang.org/)

</div>

```text
$ kubectl get pods -n prod             allowed
$ kubectl -n prod delete pod web-0     ask: kubectl verb 'delete' is not on the allowlist
$ kubectl get secret db -o yaml        BLOCKED: reads secrets
```

## Goal

Let an agent inspect a Kubernetes cluster (pods, logs, events, rollout status, ...) without being able to change it, read secrets, or switch identity, even if it is mistaken or prompt-injected.

This hook is a **convenience guard, not a security boundary**. It inspects the command string before it runs. The real enforcement should be Kubernetes RBAC (see [Caveats](#caveats)).

## How it works

A `PreToolUse` hook matches the `Bash` tool and runs `scripts/block-kubectl.sh` before every call, passing the call as JSON on stdin. The script extracts `.tool_input.command` with `jq` and decides:

| Outcome | Mechanism | Effect |
|---|---|---|
| Allow | exit `0`, no output | Command runs normally |
| Ask | prints JSON with `permissionDecision: "ask"`, exit `0` | Claude Code shows a confirmation prompt with the reason |
| Deny | message on stderr, exit `2` | Command is blocked and the message is fed back to the agent |

### Decision flow

1. **Direct API access:** `curl`/`wget` against the API server (`:6443`, `kubernetes.default`, service account token path) is always denied.
2. **Relevance check:** if the command doesn't mention `kubectl`, `kubecolor`, `helm`, `oc`, `k9s`, `kubectx` or `kubens`, it is allowed untouched.
3. **Shell indirection:** `$VAR`, `$(...)`, backticks, `eval` and `sh -c` alongside k8s tooling are always denied, since the hook can't know what they expand to.
4. **Environment overrides:** `KUBECONFIG=` and `KUBECTL_*=` are always denied.
5. **Segment splitting:** the command is split on `&&`, `||`, `;`, `|` and `&`, and every `kubectl`/`helm` invocation is checked, including ones after `xargs` or pipes.
6. **Per-invocation checks:**
   - Denied flags (always deny): `--raw`, `--as`, `--as-group`, `--as-uid`, `--token`, `--kubeconfig`, `--server`, `-s`, `--context`, `--cluster`, `--user`, `--username`, `--password`, `--insecure-skip-tls-verify`, client cert/key flags, `--cache-dir`, `--kube-*`, `--post-renderer`.
   - The verb is found as the first non-flag token, so `kubectl -n prod --context x delete` can't hide it.
   - Verb allowlist (see below). Anything else is a **verb violation**.
   - Reading secrets via `get`, `describe` or `diff` is always denied.
7. **Final decision:** a hard deny anywhere wins. Otherwise, if any verb violation was recorded and the mode is `ask`, the confirmation prompt is shown.

### What is allowed

**kubectl:**

- `get`, `describe`, `top`, `events`, `explain`, `api-resources`, `api-versions`, `version`, `diff`, `logs`
- `auth can-i`, `auth whoami`
- `config current-context`, `config get-contexts`, `config view` (but not `--raw` or `--flatten`)
- `rollout status`
- `apply` only with exactly one explicit `--dry-run=server` or `--dry-run=client`

**helm:** `list`, `ls`, `status`, `history`, `version`, `search`, `template`, `lint`, `show`

Everything else (`delete`, `exec`, `scale`, `patch`, `create`, `run`, `drain`, `port-forward`, `cp`, `debug`, `rollout restart|undo`, `helm install|upgrade|uninstall`, unknown plugins, ...) is a verb violation.

### Deny mode vs. ask mode

The `verb_violation_mode` plugin option controls how verb violations are handled. Set it in `/config` or `/plugin`:

- `"deny"`: verb violations are blocked outright (exit 2).
- `"ask"`: verb violations show a confirmation prompt, so you can approve a one-off action such as a `kubectl rollout restart`.

**Hard rules always deny, in both modes:** denied flags, reading secrets, shell indirection, environment overrides, direct API access and blocked binaries. A quick "yes" on those would defeat the guard.

The hook passes the option to the script as an argument, not through the environment, so the agent can't flip it with `VERB_VIOLATION_MODE=ask kubectl ...`. Any value other than `ask` fails closed to `deny`.

## Requirements

- macOS (works with the default bash 3.2 and BSD `grep`/`sed`) or Linux
- [`jq`](https://jqlang.org/): `brew install jq`
- Claude Code v2.1.271 or later (for the option picker)

## Install

```text
/plugin marketplace add filippobuletto/claude-plugins
/plugin install kubectl-guard@filippobuletto
```

On Claude Code 2.1.275 or later, one step works too:

```text
/plugin install kubectl-guard --marketplace filippobuletto/claude-plugins
```

Then pick the mode in `/config` (`ask` for interactive use, `deny` for unattended runs) and restart Claude Code so the hook is picked up.

## Options

| Option | Default | Meaning |
| :- | :- | :- |
| `verb_violation_mode` | `ask` | `ask` shows a confirmation prompt for commands outside the allowlist, `deny` blocks them. Hard rules always deny |

## Testing

Run the test suite from the repository root:

```bash
bash tests/run.sh
```

To try a single command by hand (the argument is the mode):

```bash
t() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bash scripts/block-kubectl.sh "${2:-ask}"; echo "exit=$?  <- $1"; }

t 'kubectl get pods -n prod'                      # allowed: no output, exit 0
t 'kubectl -n prod delete pod x'                  # ask: JSON + exit 0
t 'kubectl -n prod delete pod x' deny             # BLOCKED, exit 2
t 'kubectl get secret db -o yaml'                 # BLOCKED, exit 2 (hard rule)
```

Then start Claude Code and ask it to run `kubectl delete pod something` to confirm you see the prompt (ask mode) or the block message (deny mode).

## Caveats

**This is not a sandbox.**

- **Use RBAC as the real control.** Give the agent its own kubeconfig or ServiceAccount bound to a read-only Role (`get/list/watch`, plus `pods/log` where needed, and no `secrets`). RBAC holds regardless of how a command is phrased. Add admission policies (ValidatingAdmissionPolicy, Kyverno, Gatekeeper) and audit logging for defense in depth.
- **Scripts and files are invisible.** If the agent runs `./deploy.sh` or `make deploy` and that script calls kubectl, the hook never sees it. Restrict arbitrary script execution or run the agent in a sandbox.
- **Other clients aren't covered** beyond the basic `curl`/`wget` check: Python/Go clients, `kubectl` copied under another name, `docker run bitnami/kubectl`, and so on.
- **False positives:** any command that merely mentions `kubectl` or `helm` (like `grep kubectl notes.txt` or a commit message) is analyzed as if it were a call. Shell variables in kubectl commands (`-n $NS`) are denied.
- **Quoted separators:** a `;` or `|` inside quotes splits the command early. This causes false positives, not bypasses.
- **Flags with separate values before the verb:** only `-n`, `--namespace`, `-v`, `--v`, `--request-timeout` and `--profile` are skipped when locating the verb. Other flags that take a separate value before the verb leave the value in the verb position, which fails closed (ask or deny).
- **Logs can leak secrets.** Applications sometimes print tokens, connection strings or PII. The hook can't inspect output. Scope RBAC to specific namespaces, or remove `logs` from `ALLOWED_KUBECTL_VERBS`.
- **`logs -f` and `rollout status` can hang** until the stream ends or the rollout completes. Encourage `--tail`, `--since` or `--timeout=60s`.
- **`config view`** without `--raw` redacts credentials but still reveals cluster endpoints and user/context names.
- **`diff` and `--dry-run=server`** send manifests to the API server (read-only, but they do contact it).
- **Ask mode needs a human.** In non-interactive runs (`claude -p`, CI), there is no one to answer the prompt. Use `"deny"` there.
- **Check your permission rules.** Broad allow rules such as `Bash(kubectl:*)` in your Claude Code settings may bypass the prompt. Test that the prompt still appears and narrow those rules if it doesn't.
- **Tamper resistance:** the plugin lives in Claude Code's plugin cache under `~/.claude/plugins`, and the mode is stored in `settings.json`. An agent that can write there could edit the script, the option or the hook configuration. Deny writes to those paths in your permission rules, or run the agent in a sandbox.
- **Platform notes:** tested against macOS-compatible tools (`[[:space:]]` instead of `\b`, no bash 4 features). `kubectl.exe` and `kubecolor` are recognized; other wrappers are not.

## Customizing

Fork the repository, edit the variables at the top of `scripts/block-kubectl.sh`, and load your clone with `claude --plugin-dir /path/to/your-fork`:

- `ALLOWED_KUBECTL_VERBS`: add or remove read-only verbs (for example, remove `logs`).
- `ALLOWED_HELM_VERBS`: same for helm.
- `BLOCKED_BINARIES`: tools that are always denied.
- `DENIED_FLAGS`: regex of flags that are always denied.
- Subcommand rules (`auth`, `config`, `rollout`, `apply`) live in the `case` statement inside `check_kubectl`. For example, to allow `rollout history`, change the check to `[[ "$SUB" == "status" || "$SUB" == "history" ]]`. Note that `rollout history -o yaml` can print pod templates containing plaintext env vars.
- To make hard rules switchable too, replace `deny` with `verb_violation` for those checks. This is not recommended for flags, secrets or indirection.

## Troubleshooting

- **Nothing is blocked:** check the plugin is enabled in `/plugin`, the hook is listed in `/hooks`, and Claude Code was restarted.
- **`jq: command not found`:** `brew install jq`.
- **Hook errors on every command:** run `bash tests/run.sh` and check stderr for syntax errors.
- **Prompt never appears in ask mode:** check for broad `allow` rules in your Claude Code permissions.
