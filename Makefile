DYLIB = fix-electron-cornermask.dylib
PREFIX ?= $(HOME)/.local

.PHONY: build install uninstall apply status clean

build:
	clang -dynamiclib -framework Foundation -arch arm64 -Os \
		-o $(DYLIB) fix-electron-cornermask.m
	codesign -s - $(DYLIB)

install: build
	@mkdir -p $(PREFIX)/bin
	cp $(DYLIB) $(PREFIX)/bin/$(DYLIB)
	cp fix-electron-cornermask.m $(PREFIX)/bin/fix-electron-cornermask.m
	cp fix-electron-cornermask-apply.sh $(PREFIX)/bin/fix-electron-cornermask-apply.sh
	chmod +x $(PREFIX)/bin/fix-electron-cornermask-apply.sh
	ln -sf $(PREFIX)/bin/fix-electron-cornermask-apply.sh $(PREFIX)/bin/fix-electron
	@echo ""
	@echo "已安装到 $(PREFIX)/bin/"
	@echo "运行 'fix-electron' 或 'make apply' 应用补丁"

apply: install
	$(PREFIX)/bin/fix-electron-cornermask-apply.sh

uninstall:
	$(PREFIX)/bin/fix-electron-cornermask-apply.sh --remove 2>/dev/null || true
	rm -f $(PREFIX)/bin/$(DYLIB)
	rm -f $(PREFIX)/bin/fix-electron-cornermask.m
	rm -f $(PREFIX)/bin/fix-electron-cornermask-apply.sh
	rm -f $(PREFIX)/bin/fix-electron
	@echo "已卸载"

status:
	$(PREFIX)/bin/fix-electron-cornermask-apply.sh --dry-run

clean:
	rm -f $(DYLIB)
