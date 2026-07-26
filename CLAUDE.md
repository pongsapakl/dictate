# CLAUDE.md

## Open Challenges

### Real-Time Transcription vs Accuracy

Post-release wait is now ~1-2s (was "several seconds"), measured on the external-mic
clamshell setup after the streaming fixes. It breaks down as:

- ~400ms deliberate wait keeping the mic open past hotkey release
- ~0.3-1s for `transcribeTail()`, one real decode pass over the unconfirmed tail
- remainder: window restore and paste

The 400ms is the tunable knob. The tail decode is the floor — removing it
reintroduces the cut-off described in `docs/transcription-issues.md` Issue 4.
Whisper pads every window to 30s, so a short tail costs nearly as much as a long one.

### Accuracy on Hard Words — Open

Rare proper nouns, product names, and technical jargon transcribe poorly. Turbo's
distillation degrades exactly this class of token, so this interacts with the
"Unify on Single Model" question below. Options not yet tried, cheapest first:
post-transcription replacement map, `DecodingOptions.promptTokens` vocabulary
biasing, full large-v3 for English, LLM post-correction.

### Cursor Lock During Transcription

**What works:**
- Switching to a different app during transcription → paste returns to original app ✓

**What doesn't work:**
- Switching windows within the same app (e.g., iTerm windows) → cannot detect, pastes in wrong window
- iTerm reports all windows with same ID (4444) to Accessibility API, making detection impossible
- AppleScript approach requires authorization that users likely won't grant

**Attempted solutions:**
- CGWindowListCopyWindowInfo - returns helper windows (toolbars), not main windows
- AXFocusedWindow - works for cross-app, but iTerm returns same ID for all windows
- AppleScript for iTerm - "Not authorized to send Apple events"

### Unify on Single Model — Investigation Pending

Today: `modelVariant(for:)` swaps between turbo (default) and full large-v3 626MB (Thai). It works but the per-language reload is mildly unclean — model swap on every Thai⇆English switch, two cached models on disk, branching logic.

Cleaner alternative: use full large-v3 626MB for *everything*. Same model handles English and Thai well, no swap, no reload. Cost is decode latency — full v3 has 32 decoder layers vs turbo's 4, so per-utterance wait grows ~3-5×.

**Need to experiment:** measure daily English latency on full v3 with M1 8GB and `AudioStreamTranscriber`. If the added wait is bearable (say <2× current perceived wait), drop the per-language logic and standardize on full v3. If not, keep the split. Decision should be based on real usage, not benchmarks — the question is "does it feel slow" rather than "is it slow in ms."

## Structure

```
.venv/                    # virtual environment
requirements.txt          # dependencies
dictate.py                # main app
```

## Run

```bash
source .venv/bin/activate && python dictate.py
```

## Deploy Reminder

After completing development work that the user wants to use daily, **remind them to deploy**: the Debug build runs from Xcode but the daily app at `/Applications/Whisper.app` is a separate Release build. Personal shortcut: `whisper-ship` (zsh function). See `.claude/CLAUDE.local.md` for details. Don't run it automatically — only after the user has confirmed the change works.

## Rules

### Multi-Agent Environment

- **Multiple agents work on this codebase simultaneously**
- If you encounter a build error or test failure in a file you haven't touched, **do not fix it** - confirm with the user first
- Avoid getting stuck in loops trying to fix issues caused by other agents' in-progress work
- When in doubt about an unexpected error, ask before attempting repairs

### No Background Tasks

- **Never run commands in the background** - always run commands in the foreground
- **Wait for completion** - let each command finish before moving on

### No Wildcard Imports

- **Never use `from x import *`** - always import specific names explicitly

❌ Bad:
```python
from typing import *
```

✅ Good:
```python
import typing
```

### No Comments

- **Never add comments to code** - no exceptions
- **Never add docstrings** - no exceptions
- Code should be self-explanatory through clear naming and structure

### No Single-Use Variables

- If a variable is only read once, return or use the expression directly

❌ Bad:
```python
def get_data():
    result = calculate_something()
    return result
```

✅ Good:
```python
def get_data():
    return calculate_something()
```

### Happy Path

- **Focus on the happy path** - write if conditions for when you do actual work
- **Less code is better**

### No Try-Except

- **Never add try-except blocks** unless the user explicitly requests error handling
- **Let exceptions propagate naturally**
- **Fail fast and loud**

### No Single-Use Functions

- If a function is only used once and is not longer than 10 lines, integrate it inline

### Use Default Parameters

- Use default parameter values instead of checking if a parameter is None

### Prefer Ternary

- **Use ternary operator for simple conditional assignments**

### No Shebang

- **Never add shebang lines** - don't include `#!/usr/bin/env python3`

### Prefer Comprehensions

- **Use list/dict comprehensions instead of loops** when building collections

### Single Line Print

- **Combine related prints into a single line** when possible

### Simplicity First

- **Less is more** - always prefer the simplest solution
- **Code should be beautiful** - treat it like an art piece
