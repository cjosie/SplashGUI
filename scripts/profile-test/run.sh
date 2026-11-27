#!/usr/bin/env zsh
# Headless regression for the config store; drives the real AppModel against a temp fixture at the
# real config.json path (HOME does not redirect applicationSupportDirectory), restoring the original config.json.
set -e
cd "$(dirname "$0")"
CORE="../../Sources/SplashGUI/Core"
CFG="$HOME/Library/Application Support/SplashGUI/config.json"
# AppModel auto-starts the server on init when startOnLaunch is on; never spawn a real serve.
export SPLASHGUI_TEST=1

if pgrep -f "SplashGUI.app/Contents/MacOS/SplashGUI" >/dev/null; then
  print "SplashGUI is running — quit it first (it saves config.json on change and at exit)." && exit 2
fi
[[ -f "$CFG" ]] || { print "no config.json at $CFG"; exit 2; }

backup=$(mktemp)
cp "$CFG" "$backup"
trap 'cp "$backup" "$CFG"; rm -f "$backup"; print "config.json restored"' EXIT

# Pre-profiles schemaVersion 2 fixture: no modelProfiles key; typed values the assertions read back.
python3 - <<'EOF'
import json, os
p = os.path.expanduser("~/Library/Application Support/SplashGUI/config.json")
c = json.load(open(p))
c['run']['schemaVersion'] = 2
c['run']['kvFormat'] = 'bf16'
c['run']['maxContext'] = '100K'
# Pin the starting model (A, IQ3_XXS) and the pre-v5/v6 state; a live config may carry post-migration values.
c['run']['modelID'] = 'unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS'
c['run']['maxCacheDisk'] = '0'
c['run'].pop('idleRelease', None)
c['run'].pop('persistentCache', None)
c['engineMode'] = 'pinned'   # the schema-7 migration flips this when Homebrew is present
c['startOnLaunch'] = False   # live config may have it on; the fixture must stay inert
c['sampling']['temperature'] = 0.23
c.pop('modelProfiles', None)
json.dump(c, open(p, 'w'), indent=1)
EOF

swiftc -swift-version 5 -o /tmp/splashgui-profiletest \
  "$CORE"/AppConfig.swift "$CORE"/AppModel.swift "$CORE"/ClientConfigs.swift \
  "$CORE"/EngineInstaller.swift "$CORE"/EngineResolver.swift \
  "$CORE"/Macmon.swift "$CORE"/HardwareSampler.swift \
  "$CORE"/MachineInfo.swift "$CORE"/SessionLog.swift "$CORE"/SessionProxy.swift "$CORE"/JSONLStore.swift \
  "$CORE"/PerformanceLog.swift "$CORE"/SplashClient.swift "$CORE"/SplashServer.swift \
  "$CORE"/SSDCache.swift main.swift

/tmp/splashgui-profiletest
