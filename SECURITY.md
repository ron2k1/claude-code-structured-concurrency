# Security

## Threat model this addresses

Operational hygiene on Windows: orphan `node.exe` accumulation from Claude Code's MCP, plugin, and LSP children when the parent dies abnormally. The fix is binding the process tree to the parent's lifetime so the kernel reaps it.

## Threat model this does not address

- Malware that already has code execution on the host.
- Compromised `claude.exe` or upstream MCP server packages.
- Side-channel attacks against `claude.exe`'s working memory.
- Privilege escalation.

If your threat model includes any of those, this is not the right layer. AppLocker, WDAC, and EDR sit there.

## Capability boundaries

What the runtime can do:

- Enumerate processes the current user owns (read-only inventory).
- Terminate processes that match user-authored kill criteria in `~/.reap/config.json`. Default criteria match nothing.
- Wrap `claude.exe` in a Win32 Job Object so the kernel terminates the entire child-process tree when the wrapper exits.
- Append decisions to `~/.claude/hooks/reap.log`.

What it cannot do:

- Escalate privileges.
- Install services or scheduled tasks.
- Read or write the registry.
- Make network calls of any kind.

Full per-surface scope, with greppable verify commands, lives in the [README's Auditable section](README.md#auditable).

## Reporting a vulnerability

Open a private security advisory at <https://github.com/ron2k1/claude-code-structured-concurrency/security/advisories/new>, or email <ronilbasu@gmail.com> with subject `SECURITY:`.

Include:

- Affected version (release tag or commit SHA).
- Reproduction steps.
- Your assessment of impact.

Acknowledgement within 72 hours. Fix or mitigation in the next release.

## Verifying a release

Tags are annotated but not GPG-signed. Cross-check against commit SHAs from the [v1.0.2 release page](https://github.com/ron2k1/claude-code-structured-concurrency/releases/tag/v1.0.2):

```powershell
git fetch --tags
git rev-parse v1.0.2                  # 75759e819eaabd59d180459940bd542513d7daf8
git log --oneline v1.0.2 -3           # 75759e8, 1344e04, 8d4d2c1
```

If the SHAs don't match the release page, you have a tampered clone. Re-fetch from the canonical remote.
