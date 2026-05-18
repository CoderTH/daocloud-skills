# daocloud-skills

A generated CLI and AI skill package for DaoCloud Enterprise (DCE). It wraps the DCE REST API into a `dcectl` command-line tool and bundles a companion skill for AI agents.

## Overview

- **`dcectl`** — a CLI generated from DCE OpenAPI specs (ghippo, kpanda). Supports API discovery, search, and execution with built-in auth management.
- **`skills/dcectl`** — an AI agent skill that teaches agents how to use `dcectl` safely.

Currently supported products:

| Product | Description |
|---|---|
| `ghippo` | Global Management — users, groups, workspaces, roles, audit |
| `kpanda` | Container Management — clusters, namespaces, workloads, storage |

## Prerequisites

- Go 1.25+
- Git (for spec sync)
- Docker with [buildx](https://docs.docker.com/buildx/working-with-buildx/) (for container image builds)

## Quick Start

```bash
# Sync OpenAPI specs and regenerate code
make bootstrap

# Build dcectl
make build

# Install dcectl and symlink skill for local development
make dev
```

The `make dev` target installs `dcectl` to `/usr/local/bin` and symlinks `skills/dcectl` into `~/.agents/skills/dcectl` for live use in an AI agent runtime.

## Usage

```bash
# Log in to a DCE instance
dcectl auth login --hostname https://<dce-host>

# Browse available commands
dcectl commands --json

# Search for a command by intent
dcectl search "list clusters" --json

# Inspect a command before executing
dcectl commands show kpanda cluster list-clusters --json

# Execute a command
dcectl kpanda cluster list-clusters -o json
```

## Container Image

The image bundles the `dcectl` binary and the `skills/dcectl` directory under `/app/`, intended for use as a Kubernetes init container to distribute the tooling into a shared volume.

```bash
# Build multi-arch image locally
make image

# Build and push to registry
make image-push IMAGE_REPO=registry.example.com/dcectl IMAGE_TAG=v1.0.0
```

Default values: `IMAGE_REPO=daocloud/dcectl`, `IMAGE_TAG=latest`.

### Init Container Example

```yaml
initContainers:
  - name: install-dcectl
    image: daocloud/dcectl:latest
    command:
      - sh
      - -c
      - |
        cp /app/dcectl /target/bin/dcectl
        cp -r /app/skills/dcectl /target/.agents/skills/dcectl
    volumeMounts:
      - name: tools
        mountPath: /target

volumes:
  - name: tools
    emptyDir: {}
```

After the init container completes, the shared volume contains:

- `/target/bin/dcectl` — CLI binary
- `/target/.agents/skills/dcectl/` — AI agent skill

## Development

| Target | Description |
|---|---|
| `make bootstrap` | Sync specs + regenerate all code |
| `make specsync` | Pull latest OpenAPI specs from upstream |
| `make codegen` | Regenerate Go code and skill references from specs |
| `make sync-one SOURCE=<name>` | Sync and regenerate a single source (e.g. `ghippo`) |
| `make build` | Build `bin/dcectl` |
| `make image` | Build multi-arch image locally (`linux/amd64`, `linux/arm64`) |
| `make image-push` | Build and push multi-arch image to registry |
| `make dev` | Build, install, and symlink skill for local debugging |
| `make dev-clean` | Remove installed binary and skill symlink |
| `make clean` | Remove `.cache` and `bin` |

## Project Structure

```
.
├── cli.yaml                  # CLI name and auth config
├── specs/sources.yaml        # OpenAPI source definitions (pinned commits)
├── internal/
│   ├── generated/            # Generated Go command modules (do not edit)
│   └── overlay/              # Per-source field overrides for codegen
├── skills/dcectl/            # AI agent skill (SKILL.md + references)
├── docs/                     # Developer guides
├── cmd/dcectl/main.go        # CLI entrypoint
└── doc.go                    # Embeds cli.yaml for use by main
```

## Guides

- [Adding a new product](docs/add-new-product.md) — step-by-step guide for onboarding a new DCE product (spec source, overlay, codegen, verification)

## How It Works

1. **`specsync`** clones the pinned commit of `daocloud-api-docs` and extracts the OpenAPI JSON files into `.cache/specs-sync/`.
2. **`codegen`** reads each spec, applies the overlay from `internal/overlay/<source>.yaml`, and emits:
   - Go cobra subcommands under `internal/generated/<source>/`
   - A command index at `skills/dcectl/references/modules/<source>.md`
   - An updated `internal/generated/modules_gen.go` that mounts all modules
3. **`go build`** compiles everything into a single static binary `bin/dcectl`.

Overlay files are the only place where human-maintained configuration lives — everything else is generated and should not be edited by hand.

## Updating a Pinned Spec

Update the `pinned_tag` for the relevant source in `specs/sources.yaml`, then run:

```bash
make sync-one SOURCE=<name>
```
