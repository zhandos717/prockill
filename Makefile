APP      := ProcKill.app
DEST     := $(HOME)/Applications
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build install run uninstall clean

build:
	./build.sh

# Без перерегистрации и перезапуска расширения macOS продолжает показывать старую версию виджета.
install: build
	-pkill -x ProcKill
	-pkill -f "ProcKillWidget.appex/Contents/MacOS"
	rm -rf "$(DEST)/$(APP)"
	mkdir -p "$(DEST)"
	cp -R $(APP) "$(DEST)/"
	$(LSREGISTER) -f "$(DEST)/$(APP)"
	pluginkit -a "$(DEST)/$(APP)/Contents/PlugIns/ProcKillWidget.appex"
	open "$(DEST)/$(APP)"

run:
	open "$(DEST)/$(APP)"

uninstall:
	-pkill -x ProcKill
	pluginkit -r "$(DEST)/$(APP)/Contents/PlugIns/ProcKillWidget.appex" 2>/dev/null || true
	rm -rf "$(DEST)/$(APP)"

clean:
	rm -rf build $(APP) ProcKill.xcodeproj
