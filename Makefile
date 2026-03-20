PREFIX ?= /usr/local
BINARY = fix-electron-windowserver
LAUNCHAGENT_DIR = $(HOME)/Library/LaunchAgents
LAUNCHAGENT_LABEL = com.user.fix-electron-windowserver
LAUNCHAGENT_PLIST = $(LAUNCHAGENT_DIR)/$(LAUNCHAGENT_LABEL).plist
LOG_PATH = $(HOME)/Library/Logs/fix-electron-windowserver.log

.PHONY: build install uninstall start stop restart status log clean

build:
	swiftc -O -o $(BINARY) Sources/main.swift

install: build
	@mkdir -p $(PREFIX)/bin
	cp $(BINARY) $(PREFIX)/bin/$(BINARY)
	@mkdir -p $(LAUNCHAGENT_DIR)
	@sed -e 's|__BINARY__|$(PREFIX)/bin/$(BINARY)|g' \
	     -e 's|__LOG_PATH__|$(LOG_PATH)|g' \
	     -e 's|__LABEL__|$(LAUNCHAGENT_LABEL)|g' \
	     launchagent.plist.template > $(LAUNCHAGENT_PLIST)
	launchctl load $(LAUNCHAGENT_PLIST)
	@echo "已安装并启动 $(LAUNCHAGENT_LABEL)"
	@echo "日志: $(LOG_PATH)"

uninstall:
	-launchctl unload $(LAUNCHAGENT_PLIST) 2>/dev/null
	-rm -f $(LAUNCHAGENT_PLIST)
	-rm -f $(PREFIX)/bin/$(BINARY)
	@echo "已卸载"

start:
	launchctl load $(LAUNCHAGENT_PLIST)

stop:
	launchctl unload $(LAUNCHAGENT_PLIST)

restart: stop start

status:
	@launchctl list | grep $(LAUNCHAGENT_LABEL) || echo "未运行"

log:
	@tail -f $(LOG_PATH)

clean:
	rm -f $(BINARY)
