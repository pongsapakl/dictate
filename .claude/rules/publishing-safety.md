# Publishing Safety

**`origin` is a PUBLIC repository.** Everything committed and pushed is world-readable and
permanent — rewriting history does not reliably unpublish anything, because forks, caches,
and mirrors keep copies.

## Classification

Decide this *before* writing, not at push time.

### Tracked (public) — technical facts about the code
- Source, build config, entitlements, architecture decisions and their reasoning
- Bug analyses, measurements, library-version findings, upstream references
- Anything a stranger reading the repo would need to understand the code

Write these impersonally. "Apple silicon with constrained RAM", not a specific model.
"A local working tree may override this", not what one machine currently has.

### Untracked (`.claude/local-notes/`, `.claude/CLAUDE.local.md`) — operator-specific
- Team IDs, certificate names, account identifiers, emails
- Hardware specifics, device names, connected peripherals
- Absolute paths containing a username
- Local workflow shortcuts, machine state, permission and TCC history
- Anything phrased as "my" or "this machine"

### Never anywhere in the repo
- Credentials, keys, tokens, `.env` contents
- Transcripts or any dictation output — this app captures speech, so its output is
  unrestricted personal content by default. `.gitignore` covers the known locations;
  keep it that way.
- Recorded audio

## The test

Before adding an environment-specific detail to a tracked file, ask: **does the code make
sense without it?** If yes, it belongs in `local-notes/`. A pointer is fine — "hardware
specifics live in `.claude/local-notes/`" carries the information without publishing it.

## Enforcement

A `pre-push` hook runs `.claude/local-notes/publish-guard.sh` and blocks the push if it
matches anything on the denylist. The guard and its patterns are deliberately untracked —
a public denylist of private strings is itself a leak.

The hook is local; git never transfers hooks. **On a fresh clone it does not exist and
there is no protection.** Re-install it before the first push from any new checkout:

```
.claude/local-notes/install-hooks.sh
```

The hook is a backstop for mistakes, not a substitute for classifying correctly while
writing. It only catches patterns someone thought to add.

## Auditing what is already public

```
git grep -nI "/Users/" -- .                        # absolute paths with usernames
git grep -nIiE "<team-id>|<email>" HEAD -- .        # identifiers, against HEAD not worktree
git log --all --diff-filter=A --name-only --pretty=format: | grep -i transcript
```

Check `HEAD` or `origin/<branch>`, not the working tree — a plain `git grep` searches
uncommitted files and will report local-only strings as if they were published, which
produces false alarms.
