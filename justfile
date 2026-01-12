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
