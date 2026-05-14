SPECSYNC := go tool specsync
CODEGEN  := go tool codegen

.PHONY: bootstrap specsync codegen build clean

bootstrap: specsync codegen

specsync:
	$(SPECSYNC) -sources specs/sources.yaml

codegen:
	$(CODEGEN) \
		-manifest cli.yaml \
		-sources specs/sources.yaml \
		-overlay internal/overlay \
		-skill-root skills

# sync and regenerate a single source; usage: make sync-one SOURCE=ghippo
sync-one:
	$(SPECSYNC) -sources specs/sources.yaml -source $(SOURCE)
	$(CODEGEN) \
		-manifest cli.yaml \
		-sources specs/sources.yaml \
		-overlay internal/overlay \
		-skill-root skills

build: internal/generated
	go build -o bin/dcectl ./cmd/dcectl

internal/generated: .cache/specs-sync/ghippo/sync-state.yaml
	$(CODEGEN) \
		-manifest cli.yaml \
		-sources specs/sources.yaml \
		-overlay internal/overlay \
		-skill-root skills

.cache/specs-sync/ghippo/sync-state.yaml:
	$(SPECSYNC) -sources specs/sources.yaml

# dev: install dcectl to PATH and symlink skill into opencode for live debugging
dev: build
	@mkdir -p ~/.agents/skills
	@if [ ! -f skills/dcectl/_meta.json ]; then \
		echo '{"slug":"dcectl","version":"dev"}' > skills/dcectl/_meta.json; \
	fi
	@if [ -L ~/.agents/skills/dcectl ]; then \
		echo "skill symlink already exists"; \
	elif [ -d ~/.agents/skills/dcectl ]; then \
		echo "warning: ~/.agents/skills/dcectl is a real directory, remove it first"; \
		exit 1; \
	else \
		ln -s "$(CURDIR)/skills/dcectl" ~/.agents/skills/dcectl; \
		echo "skill symlinked: ~/.agents/skills/dcectl -> $(CURDIR)/skills/dcectl"; \
	fi
	@if command -v dcectl >/dev/null 2>&1 && [ "$$(which dcectl)" != "$(CURDIR)/bin/dcectl" ]; then \
		echo "note: dcectl in PATH is $$(which dcectl), not $(CURDIR)/bin/dcectl"; \
	fi
	cp bin/dcectl /usr/local/bin/dcectl
	@echo "done — restart opencode to pick up skill changes"

dev-clean:
	rm -f ~/.agents/skills/dcectl
	rm -f /usr/local/bin/dcectl

clean:
	rm -rf .cache bin
