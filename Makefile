DYLIB = fix-electron-cornermask.dylib
DYLIB_GENERIC = fix-easydict-cornermask.dylib
PREFIX ?= $(HOME)/.local

.PHONY: build build-generic install uninstall apply status test clean

build: $(DYLIB) $(DYLIB_GENERIC)

$(DYLIB): fix-electron-cornermask.m
	clang -dynamiclib -framework Foundation -arch arm64 -arch x86_64 -Os \
		-o $(DYLIB) fix-electron-cornermask.m
	codesign -s - $(DYLIB)

$(DYLIB_GENERIC): fix-easydict-cornermask.m
	clang -dynamiclib -framework Foundation -framework AppKit -arch arm64 -arch x86_64 -Os \
		-o $(DYLIB_GENERIC) fix-easydict-cornermask.m
	codesign -s - $(DYLIB_GENERIC)

install: build
	@mkdir -p $(PREFIX)/bin
	cp $(DYLIB) $(PREFIX)/bin/$(DYLIB)
	cp $(DYLIB_GENERIC) $(PREFIX)/bin/$(DYLIB_GENERIC)
	cp fix-electron-cornermask.m $(PREFIX)/bin/fix-electron-cornermask.m
	cp fix-easydict-cornermask.m $(PREFIX)/bin/fix-easydict-cornermask.m
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
	rm -f $(PREFIX)/bin/$(DYLIB_GENERIC)
	rm -f $(PREFIX)/bin/fix-electron-cornermask.m
	rm -f $(PREFIX)/bin/fix-easydict-cornermask.m
	rm -f $(PREFIX)/bin/fix-electron-cornermask-apply.sh
	rm -f $(PREFIX)/bin/fix-electron
	@echo "已卸载"

status:
	$(PREFIX)/bin/fix-electron-cornermask-apply.sh --dry-run

test:
	bash tests/test_entitlements.sh
	bash tests/test_resign.sh

clean:
	rm -f $(DYLIB) $(DYLIB_GENERIC)
