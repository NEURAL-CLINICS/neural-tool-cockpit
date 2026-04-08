# Fresh Mac Install

This walks through installing neural-tool-cockpit on a Mac that has never
seen it before. Assumes: macOS 13+, Homebrew installed, iTerm2 installed,
claude code installed and authenticated, zsh as the default shell.

## 1. Prerequisites

```
brew install python@3.12 git gh
```

Confirm:

```
python3 --version   # expect 3.10 or newer
git --version
gh --version
gh auth status      # must be logged in
```

Install the B612 Mono font (cockpit typeface) into
`/Users/blucid/Library/Fonts/`:

```
mkdir -p /Users/blucid/Library/Fonts
cd /tmp
curl -L -o B612.zip "https://github.com/polarsys/b612/releases/latest/download/B612-fonts.zip"
unzip -o B612.zip
cp fonts/ttf/B612Mono-*.ttf /Users/blucid/Library/Fonts/
```

Verify:

```
ls /Users/blucid/Library/Fonts/B612Mono-*.ttf
```

## 2. Clone the repo

```
mkdir -p /Users/blucid/NEURAL-CLINICS
cd /Users/blucid/NEURAL-CLINICS
git clone git@github.com:NEURAL-CLINICS/neural-tool-cockpit.git
cd neural-tool-cockpit
```

## 3. Install every artifact

```
make install
```

This copies the slash commands, shell wrapper, VPS wrapper, macOS launcher,
and dashboard into their production paths under `/Users/blucid/`.

Verify the install landed correctly:

```
make check
```

## 4. Load the shell wrapper

Ensure `~/.zshrc` sources files from `~/.zshrc.d/`. If it does not, add:

```
for f in ~/.zshrc.d/*.zsh; do source "$f"; done
```

Open a new terminal (or `source ~/.zshrc.d/30-nrl-cockpit.zsh` in the
current one). Confirm the wrapper is active:

```
type claude
# expect: claude is a shell function from ~/.zshrc.d/30-nrl-cockpit.zsh
```

## 5. Start the dashboard

```
bash /Users/blucid/.claude/orchestrator/dashboard/run.sh
```

The first run creates a venv and installs fastapi + uvicorn. Open:

```
http://127.0.0.1:7734
```

Or launch as a Chrome app window:

```
open -a "Google Chrome" --args --app=http://127.0.0.1:7734
```

(Optional) Install the launchd agent to auto-start the dashboard at login:

```
cp /Users/blucid/.claude/orchestrator/dashboard/com.neuralclinics.cockpit-dashboard.plist \
   /Users/blucid/Library/LaunchAgents/
launchctl load /Users/blucid/Library/LaunchAgents/com.neuralclinics.cockpit-dashboard.plist
launchctl start com.neuralclinics.cockpit-dashboard
```

## 6. Create the iTerm2 profile (one-time)

In iTerm2, open Preferences → Profiles → `+` and create:

- **Name:** `NC-COCKPIT-CALM-001`
- **Font:** B612 Mono 14pt
- **Background:** `#0A0A0A`
- **Foreground:** `#FFFFFF`
- **Cursor:** `#F4A258`
- **Transparency:** 0
- **Padding:** 18

Check "Use as default" only if you want cockpit colors system-wide.

## 7. First launch

```
nrl-cockpit
```

This opens the six-window cockpit layout in a dedicated Space. Every
window is a claude session registered in
`/Users/blucid/.claude/orchestrator/sessions.json` and shown on the
dashboard.

Try:

```
nrl-cockpit --minimal            # one orchestrator window only
nrl-cockpit --role plan          # one window pre-tagged as plan
```

## 8. First fork

Inside any claude session, run:

```
/fork-resume
```

The session saves state, exits, and the wrapper auto-relaunches it with
`/resume <handoff_id>`. You should see the session's `last_handoff` field
update on the dashboard.

To broadcast to every running session on Mac AND VPS:

```
/fork-all-resume
```

## 9. VPS setup (optional)

If you have a VPS running claude sessions under tmux, clone the repo there
and install the wrapper:

```
ssh ubuntu@<vps>
cd ~
git clone git@github.com:NEURAL-CLINICS/neural-tool-cockpit.git cockpit
mkdir -p ~/.config/nrl-cockpit ~/.claude/orchestrator/resume-queue ~/.claude/handoffs
cp ~/cockpit/shell/vps-wrapper.sh ~/.config/nrl-cockpit/wrapper.sh
chmod +x ~/.config/nrl-cockpit/wrapper.sh
```

Then launch claude inside tmux panes via the wrapper instead of directly.

## Troubleshooting

If `nrl-cockpit` exits without opening windows, check AppleScript
permissions in System Settings → Privacy & Security → Automation. Terminal
and Script Editor both need iTerm2 access.

If `make install` complains about missing directories, run `make dirs`
first, then retry.

If the dashboard shows an empty state even though claude is running, the
shell wrapper is not active in that shell — confirm `type claude` returns
a function and not the raw binary path.
