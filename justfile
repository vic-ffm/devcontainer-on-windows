# SPDX-License-Identifier: NCSA
# Copyright (c) 2023-2026 Aryan Ameri
#
# =============================================================================
# devcontainer-on-windows
# Task runner with CI parity to GitHub Actions
# =============================================================================

# Shell configuration for reliable pipe/redirect handling
set shell := ["bash", "-euo", "pipefail", "-c"]

# =============================================================================
# DEFAULT & HELP
# =============================================================================

# Show available commands
default:
    @just --list

# =============================================================================
# CI PIPELINE
# =============================================================================

# Run full CI pipeline (mirrors .github/workflows/ci.yml)
ci: fmt-check lint-shell lint-powershell
    @echo ""
    @echo "============================================"
    @echo "All CI checks passed!"
    @echo "============================================"

# =============================================================================
# FORMATTING
# =============================================================================

# Check shell script formatting (shfmt - Google style)
fmt-check:
    @echo "Checking shell script formatting (shfmt)..."
    shfmt -d -i 2 -ci -bn *.sh
    @echo "Formatting check passed"

# Format shell scripts (fix in place)
fmt:
    @echo "Formatting shell scripts..."
    shfmt -w -i 2 -ci -bn *.sh
    @echo "Formatting complete"

# =============================================================================
# LINTING
# =============================================================================

# Lint shell scripts (shellcheck - strictest)
lint-shell:
    @echo "Linting shell scripts (shellcheck)..."
    shellcheck -o all -S style *.sh
    @echo "Shell lint passed"

# Lint PowerShell scripts (PSScriptAnalyzer - strictest)
lint-powershell:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Linting PowerShell scripts (PSScriptAnalyzer)..."
    pwsh -NoProfile -Command '
        Set-StrictMode -Version 3.0
        $results = Invoke-ScriptAnalyzer -Path *.ps1 -Recurse -Severity Error,Warning,Information
        if ($results) {
            $results | Format-Table -AutoSize
            exit 1
        }
        Write-Host "PowerShell lint passed"
    '

# Run all lint checks
lint: lint-shell lint-powershell
    @echo "All lint checks passed"

# =============================================================================
# RELEASE
# =============================================================================

# Create a release: update version, run CI, commit, push, tag, and push tag
tag VERSION MESSAGE="":
    #!/usr/bin/env bash
    set -euo pipefail

    # Validate version format
    if [[ ! "{{VERSION}}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
        echo "ERROR: Version must match vX.Y.Z or vX.Y.Z-suffix (e.g., v1.0.0, v1.0.0-rc1)"
        exit 1
    fi

    # Extract version without 'v' prefix
    SEMVER="{{VERSION}}"
    SEMVER="${SEMVER#v}"
    echo "Updating version to $SEMVER..."

    # Update version in PowerShell script
    sed -i "s/^\(\$script:SCRIPT_VERSION = \"\)[^\"]*\"/\1$SEMVER\"/" Setup-DevContainers.ps1
    echo "Updated Setup-DevContainers.ps1"

    # Update version in Bash script
    sed -i "s/^\(declare -r SCRIPT_VERSION=\"\)[^\"]*/\1$SEMVER/" setup-wsl-devcontainers.sh
    echo "Updated setup-wsl-devcontainers.sh"

    # Run CI first
    echo "Running CI checks..."
    just ci

    # Commit changes
    MSG="${MESSAGE:-Release {{VERSION}}}"
    echo "Committing changes..."
    git add .
    git commit -m "$MSG"
    echo "Pushing to remote..."
    git push

    # Create and push tag
    echo "Creating tag {{VERSION}}..."
    git tag -a "{{VERSION}}" -m "Release {{VERSION}}"
    echo "Pushing tag to remote..."
    git push origin "{{VERSION}}"

    echo ""
    echo "============================================"
    echo "Release {{VERSION}} complete!"
    echo "GitHub Actions will now build and publish."
    echo "============================================"
