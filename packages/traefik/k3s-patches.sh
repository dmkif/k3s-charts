#!/bin/bash
#
# k3s-patches.sh - Semantic patches for Traefik Helm chart
#
# This script applies k3s/Rancher-specific modifications to the upstream
# Traefik Helm chart using semantic operations rather than unified diffs.
#
# Benefits over .patch files:
#   - Survives upstream refactoring
#   - Idempotent (safe to run multiple times)
#   - Self-documenting
#   - Validates results after application
#
# Usage: ./k3s-patches.sh <chart-directory> [traefik-version]
#
# Example:
#   ./k3s-patches.sh ./charts v3.4.3
#   ./k3s-patches.sh ./charts          # Uses default version
#

set -euo pipefail

# Configuration
DEFAULT_TRAEFIK_VERSION="v3.6.12"
IMAGE_REPOSITORY="rancher/mirrored-library-traefik"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Check for required tools
check_dependencies() {
    local missing=()

    if ! command -v yq &> /dev/null; then
        missing+=("yq (https://github.com/mikefarah/yq)")
    fi

    if ! command -v sed &> /dev/null; then
        missing+=("sed")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        exit 1
    fi

    # Check yq version (need v4+)
    local yq_version
    yq_version=$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ "${yq_version%%.*}" -lt 4 ]]; then
        log_error "yq version 4+ required (found: $yq_version)"
        exit 1
    fi
}

# =============================================================================
# PATCH 1: values.yaml - Image configuration and global settings
# =============================================================================
patch_values_yaml() {
    local values_file="$1"
    local traefik_version="$2"

    log_step "Patching values.yaml"

    if [ ! -f "$values_file" ]; then
        log_error "values.yaml not found: $values_file"
        return 1
    fi

    # 1. Remove image.registry if present
    if yq -e '.image.registry' "$values_file" &>/dev/null; then
        log_info "  Removing image.registry"
        yq -i 'del(.image.registry)' "$values_file"
    else
        log_info "  image.registry already removed"
    fi

    # 2. Set image.repository
    local current_repo
    current_repo=$(yq '.image.repository' "$values_file")
    if [ "$current_repo" != "$IMAGE_REPOSITORY" ]; then
        log_info "  Setting image.repository = $IMAGE_REPOSITORY"
        yq -i ".image.repository = \"$IMAGE_REPOSITORY\"" "$values_file"
    else
        log_info "  image.repository already set"
    fi

    # 3. Set image.tag
    local current_tag
    current_tag=$(yq '.image.tag // ""' "$values_file")
    if [ "$current_tag" != "$traefik_version" ]; then
        log_info "  Setting image.tag = $traefik_version"
        yq -i ".image.tag = \"$traefik_version\"" "$values_file"
    else
        log_info "  image.tag already set"
    fi

    # 4. Add global.systemDefaultRegistry if not present
    if ! yq -e '.global.systemDefaultRegistry' "$values_file" &>/dev/null; then
        log_info "  Adding global.systemDefaultRegistry = \"\""
        # Insert systemDefaultRegistry as first key under global
        yq -i '.global = {"systemDefaultRegistry": ""} + .global' "$values_file"
    else
        log_info "  global.systemDefaultRegistry already exists"
    fi

    # 5. Set global.checkNewVersion = false
    local current_check
    current_check=$(yq '.global.checkNewVersion' "$values_file")
    if [ "$current_check" != "false" ]; then
        log_info "  Setting global.checkNewVersion = false"
        yq -i '.global.checkNewVersion = false' "$values_file"
    else
        log_info "  global.checkNewVersion already false"
    fi

    log_info "  values.yaml patched successfully"
}

# =============================================================================
# PATCH 2: templates/_helpers.tpl - Image name helper and registry helper
# =============================================================================
patch_helpers_tpl() {
    local helpers_file="$1"

    log_step "Patching templates/_helpers.tpl"

    if [ ! -f "$helpers_file" ]; then
        log_error "_helpers.tpl not found: $helpers_file"
        return 1
    fi

    # 1. Change image-name helper to use repository:tag instead of registry/repository:tag
    # Look for the pattern with image.registry and replace with just repository:tag
    if grep -q '\.Values\.image\.registry' "$helpers_file"; then
        log_info "  Removing image.registry from traefik.image-name helper"
        # Replace: printf "%s/%s:%s" .Values.image.registry .Values.image.repository
        # With:    printf "%s:%s" .Values.image.repository
        sed -i 's|{{- printf "%s/%s:%s" \.Values\.image\.registry \.Values\.image\.repository|{{- printf "%s:%s" .Values.image.repository|g' "$helpers_file"
    else
        log_info "  image.registry already removed from helper"
    fi

    # 2. Add system_default_registry helper if not present
    if ! grep -q 'define "system_default_registry"' "$helpers_file"; then
        log_info "  Adding system_default_registry helper"
        cat >> "$helpers_file" << 'EOF'

{{- define "system_default_registry" -}}
{{- if .Values.global.systemDefaultRegistry -}}
{{- printf "%s/" .Values.global.systemDefaultRegistry -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}
EOF
    else
        log_info "  system_default_registry helper already exists"
    fi

    log_info "  _helpers.tpl patched successfully"
}

# =============================================================================
# PATCH 3: templates/_podtemplate.tpl - Container image with registry prefix
# =============================================================================
patch_podtemplate_tpl() {
    local podtemplate_file="$1"

    log_step "Patching templates/_podtemplate.tpl"

    if [ ! -f "$podtemplate_file" ]; then
        log_error "_podtemplate.tpl not found: $podtemplate_file"
        return 1
    fi

    # Check if system_default_registry is already used in image line
    if grep -q 'system_default_registry.*traefik.image-name' "$podtemplate_file"; then
        log_info "  Container image already prefixed with system_default_registry"
    else
        log_info "  Adding system_default_registry prefix to container image"

        # Pattern 1: - image: {{ template "traefik.image-name" . }}
        # Pattern 2: - image: "{{ template "traefik.image-name" . }}"
        # Replace with: - image: "{{ template "system_default_registry" . }}{{ template "traefik.image-name" . }}"

        sed -i 's|- image: {{ template "traefik.image-name" \. }}|- image: "{{ template "system_default_registry" . }}{{ template "traefik.image-name" . }}"|g' "$podtemplate_file"
        sed -i 's|- image: "{{ template "traefik.image-name" \. }}"|- image: "{{ template "system_default_registry" . }}{{ template "traefik.image-name" . }}"|g' "$podtemplate_file"
    fi

    log_info "  _podtemplate.tpl patched successfully"
}

# =============================================================================
# PATCH 4: templates/rbac/clusterrole.yaml - Remove semverCompare for configmaps
# =============================================================================
patch_clusterrole_yaml() {
    local clusterrole_file="$1"

    log_step "Patching templates/rbac/clusterrole.yaml"

    if [ ! -f "$clusterrole_file" ]; then
        log_error "clusterrole.yaml not found: $clusterrole_file"
        return 1
    fi

    # Remove semverCompare condition from configmaps permission
    # From: {{- if and .Values.providers.kubernetesCRD.enabled (semverCompare ">=v3.4.0-0" $version) }}
    # To:   {{- if .Values.providers.kubernetesCRD.enabled }}

    if grep -q 'kubernetesCRD.enabled.*semverCompare.*configmaps' "$clusterrole_file" || \
       grep -q 'and .Values.providers.kubernetesCRD.enabled (semverCompare' "$clusterrole_file"; then
        log_info "  Removing semverCompare gate from configmaps permission"
        sed -i 's|{{- if and \.Values\.providers\.kubernetesCRD\.enabled (semverCompare "[^"]*" \$version) }}|{{- if .Values.providers.kubernetesCRD.enabled }}|g' "$clusterrole_file"
    else
        log_info "  semverCompare gate already removed or not present"
    fi

    log_info "  clusterrole.yaml patched successfully"
}

# =============================================================================
# PATCH 5: CRD chart template - Sync version/appVersion with main chart
# =============================================================================
patch_crd_template_chart() {
    local chart_dir="$1"
    local traefik_version="$2"

    log_step "Patching CRD chart template (if present)"

    local chart_yaml="$chart_dir/Chart.yaml"
    if [ ! -f "$chart_yaml" ]; then
        log_warn "  Chart.yaml not found in chart dir; skipping CRD template patch"
        return 0
    fi

    local chart_version
    chart_version=$(yq '.version' "$chart_yaml")
    if [ -z "$chart_version" ] || [ "$chart_version" = "null" ]; then
        log_warn "  Could not read chart version; skipping CRD template patch"
        return 0
    fi

    local crd_template_chart="$chart_dir/../templates/crd-template/Chart.yaml"
    if [ ! -f "$crd_template_chart" ]; then
        log_warn "  CRD template Chart.yaml not found; skipping"
        return 0
    fi

    log_info "  Setting CRD appVersion = $traefik_version"
    log_info "  Setting CRD version = $chart_version"
    yq -i ".appVersion = \"${traefik_version}\" | .version = \"${chart_version}\"" "$crd_template_chart"

    log_info "  CRD chart template patched successfully"
}

# =============================================================================
# VALIDATION: Verify all patches were applied correctly
# =============================================================================
validate_patches() {
    local chart_dir="$1"
    local traefik_version="$2"
    local errors=0

    log_step "Validating patches"

    # Validate values.yaml
    local values_file="$chart_dir/values.yaml"
    if [ -f "$values_file" ]; then
        # Check image.repository
        local repo
        repo=$(yq '.image.repository' "$values_file")
        if [ "$repo" != "$IMAGE_REPOSITORY" ]; then
            log_error "  FAIL: image.repository = $repo (expected: $IMAGE_REPOSITORY)"
            ((errors++))
        else
            log_info "  OK: image.repository = $IMAGE_REPOSITORY"
        fi

        # Check image.tag
        local tag
        tag=$(yq '.image.tag' "$values_file")
        if [ "$tag" != "$traefik_version" ]; then
            log_error "  FAIL: image.tag = $tag (expected: $traefik_version)"
            ((errors++))
        else
            log_info "  OK: image.tag = $traefik_version"
        fi

        # Check global.systemDefaultRegistry exists
        if yq -e '.global.systemDefaultRegistry' "$values_file" &>/dev/null; then
            log_info "  OK: global.systemDefaultRegistry exists"
        else
            log_error "  FAIL: global.systemDefaultRegistry missing"
            ((errors++))
        fi

        # Check global.checkNewVersion
        local check
        check=$(yq '.global.checkNewVersion' "$values_file")
        if [ "$check" = "false" ]; then
            log_info "  OK: global.checkNewVersion = false"
        else
            log_error "  FAIL: global.checkNewVersion = $check (expected: false)"
            ((errors++))
        fi

        # Check image.registry is removed
        if yq -e '.image.registry' "$values_file" &>/dev/null; then
            log_error "  FAIL: image.registry still exists (should be removed)"
            ((errors++))
        else
            log_info "  OK: image.registry removed"
        fi
    fi

    # Validate _helpers.tpl
    local helpers_file="$chart_dir/templates/_helpers.tpl"
    if [ -f "$helpers_file" ]; then
        if grep -q 'define "system_default_registry"' "$helpers_file"; then
            log_info "  OK: system_default_registry helper exists"
        else
            log_error "  FAIL: system_default_registry helper missing"
            ((errors++))
        fi

        if grep -q '\.Values\.image\.registry' "$helpers_file"; then
            log_error "  FAIL: image.registry still referenced in helper"
            ((errors++))
        else
            log_info "  OK: image.registry removed from helper"
        fi
    fi

    # Validate _podtemplate.tpl
    local podtemplate_file="$chart_dir/templates/_podtemplate.tpl"
    if [ -f "$podtemplate_file" ]; then
        if grep -q 'system_default_registry.*traefik.image-name' "$podtemplate_file"; then
            log_info "  OK: Container image uses system_default_registry"
        else
            log_error "  FAIL: Container image not prefixed with system_default_registry"
            ((errors++))
        fi
    fi

    # Validate clusterrole.yaml
    local clusterrole_file="$chart_dir/templates/rbac/clusterrole.yaml"
    if [ -f "$clusterrole_file" ]; then
        if grep -q 'and .Values.providers.kubernetesCRD.enabled (semverCompare' "$clusterrole_file"; then
            log_error "  FAIL: semverCompare gate still present for configmaps"
            ((errors++))
        else
            log_info "  OK: semverCompare gate removed from configmaps"
        fi
    fi

    # Validate CRD chart template if present
    local chart_yaml="$chart_dir/Chart.yaml"
    local crd_template_chart="$chart_dir/../templates/crd-template/Chart.yaml"
    if [ -f "$chart_yaml" ] && [ -f "$crd_template_chart" ]; then
        local chart_version
        chart_version=$(yq '.version' "$chart_yaml")
        local crd_version
        crd_version=$(yq '.version' "$crd_template_chart")
        if [ "$crd_version" = "$chart_version" ]; then
            log_info "  OK: CRD chart version matches main chart ($chart_version)"
        else
            log_error "  FAIL: CRD chart version = $crd_version (expected: $chart_version)"
            ((errors++))
        fi

        local crd_app_version
        crd_app_version=$(yq '.appVersion' "$crd_template_chart")
        if [ "$crd_app_version" = "$traefik_version" ]; then
            log_info "  OK: CRD appVersion = $traefik_version"
        else
            log_error "  FAIL: CRD appVersion = $crd_app_version (expected: $traefik_version)"
            ((errors++))
        fi
    fi

    if [ $errors -gt 0 ]; then
        log_error "Validation failed with $errors error(s)"
        return 1
    fi

    log_info "All patches validated successfully"
    return 0
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <chart-directory> [traefik-version]

Apply k3s/Rancher-specific patches to the upstream Traefik Helm chart.

Arguments:
  <chart-directory>   Path to the extracted Traefik chart
  [traefik-version]   Traefik version tag (default: $DEFAULT_TRAEFIK_VERSION)

Options:
  -v, --validate-only   Only validate, don't apply patches
  -h, --help            Show this help message

Examples:
  $(basename "$0") ./charts
  $(basename "$0") ./charts v3.5.0
  $(basename "$0") --validate-only ./charts

EOF
}

main() {
    local validate_only=false
    local chart_dir=""
    local traefik_version="$DEFAULT_TRAEFIK_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--validate-only)
                validate_only=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -z "$chart_dir" ]; then
                    chart_dir="$1"
                else
                    traefik_version="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$chart_dir" ]; then
        log_error "Missing required argument: <chart-directory>"
        usage
        exit 1
    fi

    if [ ! -d "$chart_dir" ]; then
        log_error "Directory not found: $chart_dir"
        exit 1
    fi

    # Ensure version starts with 'v'
    if [[ ! "$traefik_version" =~ ^v ]]; then
        traefik_version="v$traefik_version"
    fi

    echo ""
    echo "========================================"
    echo " k3s Traefik Chart Patches"
    echo "========================================"
    echo " Chart directory: $chart_dir"
    echo " Traefik version: $traefik_version"
    echo " Mode: $([ "$validate_only" = true ] && echo "Validate only" || echo "Apply patches")"
    echo "========================================"
    echo ""

    check_dependencies

    if [ "$validate_only" = true ]; then
        validate_patches "$chart_dir" "$traefik_version"
        exit $?
    fi

    # Apply patches
    patch_values_yaml "$chart_dir/values.yaml" "$traefik_version"
    echo ""
    patch_helpers_tpl "$chart_dir/templates/_helpers.tpl"
    echo ""
    patch_podtemplate_tpl "$chart_dir/templates/_podtemplate.tpl"
    echo ""
    patch_clusterrole_yaml "$chart_dir/templates/rbac/clusterrole.yaml"
    echo ""
    patch_crd_template_chart "$chart_dir" "$traefik_version"
    echo ""

    # Validate
    validate_patches "$chart_dir" "$traefik_version"
    local result=$?

    echo ""
    if [ $result -eq 0 ]; then
        echo "========================================"
        echo " All patches applied successfully!"
        echo "========================================"
    else
        echo "========================================"
        echo " Patching completed with errors"
        echo "========================================"
    fi

    return $result
}

main "$@"
