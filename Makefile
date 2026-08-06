APP_NAME    := WorkSwitch
BUNDLE_ID   := com.lorenzospellman.workswitch
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: build app run install uninstall dump test reset-perms clean doctor \
        signing-identity extension extension-deps host-manifest setup bridge-status

## Create the stable self-signed code-signing identity (idempotent, run once).
## Without it, ad-hoc signing breaks the Accessibility grant on every rebuild.
signing-identity:
	@bash scripts/setup_signing_identity.sh

## Report signing identity, all copies on disk, and live Accessibility trust.
doctor:
	@bash scripts/doctor.sh

## Run the ranking and merge checks.
## (XCTest ships with Xcode, which is not installed, so these run via a debug flag.)
test: build
	@.build/release/$(APP_NAME) --self-test

## --- Chrome integration (Milestone 2) ---

extension-deps:
	@cd chrome-extension && npm install

## Compile the extension's TypeScript into chrome-extension/dist
extension:
	@cd chrome-extension && npm run build
	@echo "==> Built chrome-extension/dist"
	@echo "==> Load unpacked from: $(CURDIR)/chrome-extension"

## Install the Chrome native messaging host manifest. Requires 'make install' first.
host-manifest:
	@bash scripts/install_host_manifest.sh

## One-shot setup: app, extension, and host manifest.
setup: signing-identity install extension host-manifest
	@echo ""
	@echo "Next: load $(CURDIR)/chrome-extension as an unpacked extension in Chrome,"
	@echo "then restart Chrome."

## Show whether the bridge socket exists and who is connected.
bridge-status:
	@SOCK="$(HOME)/Library/Application Support/WorkSwitch/bridge.sock"; \
	if [ -S "$$SOCK" ]; then echo "socket present: $$SOCK"; else echo "socket MISSING (is WorkSwitch running?)"; fi
	@echo "--- recent bridge logs ---"
	@log show --predicate 'eventMessage CONTAINS "[WorkSwitch]"' --last 5m --style compact 2>/dev/null \
	  | grep -i bridge | tail -20 || echo "(no logs; try running the app from a terminal)"


## Compile the binary only.
build:
	swift build -c release

## Build the .app bundle into ./build
app:
	@bash scripts/build_app.sh

## Install to a fixed path. The path must stay stable: macOS ties the Accessibility
## grant to the bundle identity, and a moving app re-prompts every time.
install: app
	@mkdir -p "$(INSTALL_DIR)"
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@cp -R "build/$(APP_NAME).app" "$(INSTALLED)"
	@# The staging copy is removed so only one bundle exists. Two copies are two TCC
	@# identities, and launching the wrong one looks exactly like a revoked permission.
	@rm -rf "build/$(APP_NAME).app"
	@echo "==> Installed $(INSTALLED)"

## Build, install, and (re)launch.
run: install
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@open "$(INSTALLED)"
	@echo "==> Running. Press Ctrl-Space to open the switcher."

## Print the enumerated destinations as JSON and exit.
## Requires the invoking terminal to hold Accessibility permission.
dump: build
	@.build/release/$(APP_NAME) --dump-destinations

## Clear a stale Accessibility grant, then re-add the app in System Settings.
## With a stable signing identity this should rarely be needed.
reset-perms:
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@echo "==> Reset. Re-grant in System Settings > Privacy & Security > Accessibility."

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@echo "==> Removed $(INSTALLED)"

clean:
	@rm -rf .build build
