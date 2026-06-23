#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Global variables
# ---------------------------------------------------------------------------
ORG_KEY=""
PROJECT_KEY=""
PROJECT_NAME=""
TOKEN=""
SERVER_URL="https://sonarcloud.io"
DRY_RUN=false
VERBOSE=false
FORCE=false
INTEGRATE_CLAUDE=false
SONAR_CLI=""
SCANNER_VERSION="8.0.1.6346"
SCANNER_CMD=""
USE_DOCKER=false
MSG_SCANNER_READY="sonar-scanner ready."

TMPFILES=()
mktmp() {
    local f
    f="$(mktemp /tmp/apply-sonar-XXXXXX)"
    TMPFILES+=("$f")
    echo "$f"
}
# shellcheck disable=SC2329
cleanup() { rm -f "${TMPFILES[@]+"${TMPFILES[@]}"}"; }
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------
_color_reset=""
_color_red=""
_color_green=""
_color_yellow=""
_color_dim=""

if [[ -t 2 ]]; then
    _color_reset=$'\033[0m'
    _color_red=$'\033[0;31m'
    _color_green=$'\033[0;32m'
    _color_yellow=$'\033[0;33m'
    _color_dim=$'\033[2m'
fi

log_info() {
    echo "${_color_dim}[INFO]${_color_reset} $*" >&2
}

log_error() {
    local msg="$1"
    echo "${_color_red}[ERROR]${_color_reset} $msg" >&2
    shift
    for line in "$@"; do
        echo "        $line" >&2
    done
}

log_success() {
    echo "${_color_green}[OK]${_color_reset} $*" >&2
}

log_verbose() {
    if [[ "$VERBOSE" = true ]]; then
        echo "${_color_dim}[VERBOSE]${_color_reset} $*" >&2
    fi
}

log_dryrun() {
    echo "${_color_yellow}[DRY RUN]${_color_reset} $*" >&2
}

# ---------------------------------------------------------------------------
# Function: usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: apply-sonar [OPTIONS]

Sets up a SonarQube Cloud project from a local git repository.
Handles auth, project creation, config generation, and first scan.

Options:
  --org <key>            Organization key (auto-detected from auth)
  --key <key>            Project key (auto-generated from org + repo name)
  --name <name>          Project display name (defaults to repo name)
  --token <token>        Auth token (skips browser login)
  --integrate-claude     Also run 'sonar integrate claude' after setup
  --force                Overwrite existing config files
  --dry-run              Show what would happen without making changes
  --verbose              Show detailed output
  --help                 Show this help message
EOF
}

# ---------------------------------------------------------------------------
# Function: parse_args
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        local flag="$1"
        case "$flag" in
            --org|--key|--name|--token)
                if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                    log_error "Missing value for $flag"
                    exit 1
                fi
                local value="$2"
                case "$flag" in
                    --org)   ORG_KEY="$value" ;;
                    --key)   PROJECT_KEY="$value" ;;
                    --name)  PROJECT_NAME="$value" ;;
                    --token) TOKEN="$value" ;;
                    *)       ;;
                esac
                shift 2
                ;;
            --integrate-claude)
                INTEGRATE_CLAUDE=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $flag"
                usage
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Function: check_prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    local missing=""

    for tool in git curl jq unzip; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing="${missing}  - ${tool}\n"
        fi
    done

    if [[ -n "$missing" ]]; then
        log_error "Missing required tools:" \
            "" \
            "$(printf '%b' "$missing")" \
            "Install them and re-run this script."
        exit 1
    fi

    log_verbose "All prerequisite tools found."

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not inside a git repository." \
            "Run this command from inside a git project directory."
        exit 1
    fi

    log_verbose "Inside a git repository."
}

# ---------------------------------------------------------------------------
# Function: ensure_sonar_cli
# ---------------------------------------------------------------------------
ensure_sonar_cli() {
    local local_bin="$HOME/.local/share/sonarqube-cli/bin/sonar"

    if command -v sonar > /dev/null 2>&1; then
        SONAR_CLI="$(command -v sonar)"
        log_verbose "Found sonar CLI on PATH: $SONAR_CLI"
        return
    fi

    if [[ -x "$local_bin" ]]; then
        SONAR_CLI="$local_bin"
        log_verbose "Found sonar CLI at: $SONAR_CLI"
        return
    fi

    log_info "The sonar CLI is required but was not found."

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would install sonar CLI"
        SONAR_CLI="$local_bin"
        return
    fi

    printf "Would you like to install it now? [y/N] " >&2
    local answer
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_error "sonar CLI is required." \
            "Install it manually: https://docs.sonarsource.com/sonarqube-cloud/advanced-setup/ci-based-analysis/sonarqube-cli/"
        exit 1
    fi

    log_info "Installing sonar CLI..."
    local install_exit=0
    set +e
    curl -fsSL --connect-timeout 10 --max-time 300 \
        https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh | bash
    install_exit=$?
    set -e
    if [[ "$install_exit" -ne 0 ]]; then
        log_error "sonar CLI installation script failed (exit $install_exit)." \
            "Try installing manually: https://docs.sonarsource.com/sonarqube-cloud/advanced-setup/ci-based-analysis/sonarqube-cli/"
        exit 1
    fi

    if [[ ! -x "$local_bin" ]]; then
        log_error "Installation failed — sonar CLI not found at $local_bin." \
            "Try installing manually: https://docs.sonarsource.com/sonarqube-cloud/advanced-setup/ci-based-analysis/sonarqube-cli/"
        exit 1
    fi

    SONAR_CLI="$local_bin"
    log_success "sonar CLI installed at: $SONAR_CLI"
}

# ---------------------------------------------------------------------------
# Function: resolve_token
# ---------------------------------------------------------------------------
resolve_token() {
    local sources=()
    if [[ -n "$TOKEN" ]]; then
        sources+=("provided:$TOKEN")
    fi
    if [[ -n "${SONARQUBE_CLI_TOKEN:-}" ]]; then
        sources+=("SONARQUBE_CLI_TOKEN:$SONARQUBE_CLI_TOKEN")
    fi
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        sources+=("SONAR_TOKEN:$SONAR_TOKEN")
    fi

    if [[ ${#sources[@]} -eq 0 ]]; then
        log_error "No API token available." \
            "The sonar CLI stores tokens in the OS keychain, which this script cannot access directly." \
            "Set SONAR_TOKEN environment variable, or pass --token <token>." \
            "Generate a token at: $SERVER_URL/account/security"
        exit 1
    fi

    if [[ "$DRY_RUN" = true ]]; then
        local first="${sources[0]}"
        TOKEN="${first#*:}"
        log_dryrun "Would validate token (skipping in dry-run)."
        return
    fi

    local validate_url="$SERVER_URL/api/authentication/validate"

    for entry in "${sources[@]}"; do
        local label="${entry%%:*}"
        local candidate="${entry#*:}"

        log_verbose "Validating token from $label..."
        local response
        local curl_exit=0
        set +e
        response="$(curl -sS --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer $candidate" "$validate_url")"
        curl_exit=$?
        set -e
        if [[ "$curl_exit" -ne 0 ]]; then
            log_error "Could not reach SonarQube Cloud to validate token. Check your network connection."
            exit 1
        fi
        if echo "$response" | jq -e '.valid == true' > /dev/null 2>&1; then
            TOKEN="$candidate"
            log_verbose "Token ($label) is valid."
            return
        fi
        log_verbose "Token from $label is not valid."
    done

    log_error "No valid API token found." \
        "Generate a new token at: $SERVER_URL/account/security"
    exit 1
}

# ---------------------------------------------------------------------------
# Function: parse_auth_status
# ---------------------------------------------------------------------------
parse_auth_status() {
    local status_output="$1"

    if [[ -z "$ORG_KEY" ]]; then
        local parsed_org
        parsed_org="$(echo "$status_output" | grep -E "^Org" | head -1 | awk '{print $NF}' || true)"
        if [[ -n "$parsed_org" ]]; then
            ORG_KEY="$parsed_org"
            log_verbose "Detected org key from auth status: $ORG_KEY"
        fi
    fi

    local parsed_server
    parsed_server="$(echo "$status_output" | grep -E "^Server" | head -1 | awk '{print $NF}' || true)"
    if [[ -n "$parsed_server" ]]; then
        SERVER_URL="$parsed_server"
        log_verbose "Detected server URL from auth status: $SERVER_URL"
    fi
}

# ---------------------------------------------------------------------------
# Function: ensure_auth
# ---------------------------------------------------------------------------
ensure_auth() {
    if [[ -n "$TOKEN" ]] && [[ -n "$ORG_KEY" ]]; then
        if [[ -n "$SONAR_CLI" ]]; then
            log_info "Logging in with provided token and org..."
            if [[ "$DRY_RUN" = true ]]; then
                log_dryrun "Would run: sonar auth login -t <token> -o $ORG_KEY"
            else
                local login_exit=0
                set +e
                "$SONAR_CLI" auth login -t "$TOKEN" -o "$ORG_KEY"
                login_exit=$?
                set -e
                if [[ "$login_exit" -ne 0 ]]; then
                    log_error "sonar CLI login failed (exit $login_exit)." \
                        "Check that your CLI version supports -t and -o flags, or log in manually: sonar auth login"
                    exit 1
                fi
            fi
        fi
        resolve_token
        return
    fi

    local status_output
    local status_exit=0
    set +e
    status_output="$("$SONAR_CLI" auth status 2>&1)"
    status_exit=$?
    set -e

    if [[ "$status_exit" -eq 0 ]]; then
        log_success "Already authenticated with SonarQube Cloud."
        parse_auth_status "$status_output"
    else
        if [[ -n "$TOKEN" ]] && [[ -z "$ORG_KEY" ]]; then
            log_error "--org is required when using --token." \
                "Pass --org <key> to specify the organization."
            exit 1
        fi

        log_info "No SonarQube Cloud authentication found. Opening browser to log in..."

        if [[ "$DRY_RUN" = true ]]; then
            log_dryrun "Would run: sonar auth login"
        else
            local login_exit=0
            set +e
            "$SONAR_CLI" auth login
            login_exit=$?
            set -e
            if [[ "$login_exit" -ne 0 ]]; then
                log_error "Authentication failed." \
                    "Try again, or pass --token <token> and --org <key> directly."
                exit 1
            fi

            local recheck_output
            local recheck_exit=0
            set +e
            recheck_output="$("$SONAR_CLI" auth status 2>&1)"
            recheck_exit=$?
            set -e

            if [[ "$recheck_exit" -ne 0 ]]; then
                log_error "Authentication failed after login attempt." \
                    "Try again, or pass --token <token> and --org <key> directly."
                exit 1
            fi

            log_success "Authentication successful."
            parse_auth_status "$recheck_output"
        fi
    fi

    if [[ -z "$ORG_KEY" ]]; then
        log_error "Could not determine organization key." \
            "Pass --org <key> to specify the organization."
        exit 1
    fi

    resolve_token
}

# ---------------------------------------------------------------------------
# Function: detect_project_info
# ---------------------------------------------------------------------------
detect_project_info() {
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"

    local repo_name
    if [[ -n "$remote_url" ]]; then
        repo_name="$(echo "$remote_url" | sed 's/\.git$//' | sed 's:.*/::' )"
    else
        repo_name="$(basename "$(git rev-parse --show-toplevel)")"
    fi

    if [[ -z "$PROJECT_KEY" ]]; then
        PROJECT_KEY="${ORG_KEY}_${repo_name}"
        PROJECT_KEY="$(echo "$PROJECT_KEY" | sed 's/[^a-zA-Z0-9_.:-]/-/g' | cut -c1-400)"
    fi

    if [[ "$PROJECT_KEY" =~ [^a-zA-Z0-9_.:-] ]]; then
        log_error "Invalid project key: $PROJECT_KEY" \
            "Project keys may only contain letters, digits, underscores, dots, colons, and hyphens."
        exit 1
    fi

    if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$repo_name"
    fi

    log_info "Detected project configuration:"
    echo "       Organization:   $ORG_KEY" >&2
    echo "       Project key:    $PROJECT_KEY" >&2
    echo "       Project name:   $PROJECT_NAME" >&2
}

# ---------------------------------------------------------------------------
# Function: ensure_project_exists
# ---------------------------------------------------------------------------
ensure_project_exists() {
    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would check/create project: $PROJECT_KEY"
        return
    fi

    local tmp_body
    tmp_body="$(mktmp)"

    local http_code
    local curl_exit=0
    set +e
    http_code="$(curl -sS --connect-timeout 10 --max-time 30 \
        -o "$tmp_body" -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$SERVER_URL/api/components/show?component=$PROJECT_KEY")"
    curl_exit=$?
    set -e
    if [[ "$curl_exit" -ne 0 ]]; then
        log_error "Could not reach SonarQube Cloud (curl exit $curl_exit)." \
            "Check your network connection and try again."
        exit 1
    fi

    case "$http_code" in
        200)
            log_success "Project already exists in SonarQube Cloud."
            return
            ;;
        404)
            log_verbose "Project does not exist yet — will create."
            ;;
        401|403)
            log_error "Authentication/authorization error (HTTP $http_code)." \
                "Check that your token has the 'Administer' permission for the organization." \
                "Generate a new token at: $SERVER_URL/account/security"
            exit 1
            ;;
        *)
            log_error "Unexpected response checking project (HTTP $http_code):" \
                "$(cat "$tmp_body" 2>/dev/null || echo '(no body)')"
            exit 1
            ;;
    esac

    local tmp_create
    tmp_create="$(mktmp)"

    local create_code
    curl_exit=0
    set +e
    create_code="$(curl -sS --connect-timeout 10 --max-time 30 \
        -o "$tmp_create" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "organization=$ORG_KEY" \
        --data-urlencode "project=$PROJECT_KEY" \
        --data-urlencode "name=$PROJECT_NAME" \
        "$SERVER_URL/api/projects/create")"
    curl_exit=$?
    set -e
    if [[ "$curl_exit" -ne 0 ]]; then
        log_error "Could not reach SonarQube Cloud (curl exit $curl_exit)." \
            "Check your network connection and try again."
        exit 1
    fi

    case "$create_code" in
        2*)
            local create_response
            create_response="$(cat "$tmp_create")"
            if echo "$create_response" | jq -e '.project' > /dev/null 2>&1; then
                log_success "Project created: $PROJECT_KEY"
            elif echo "$create_response" | grep -qi "key already exists"; then
                log_error "Project key '$PROJECT_KEY' already exists." \
                    "Use --key <key> to specify a different project key."
                exit 1
            else
                local err_msg
                err_msg="$(echo "$create_response" | jq -r '.errors[]?.msg // empty' 2>/dev/null || echo "$create_response")"
                log_error "Failed to create project:" "$err_msg"
                exit 1
            fi
            ;;
        401|403)
            log_error "Authentication/authorization error creating project (HTTP $create_code)." \
                "Check that your token has the 'Administer' permission for the organization." \
                "Generate a new token at: $SERVER_URL/account/security"
            exit 1
            ;;
        *)
            log_error "Unexpected response creating project (HTTP $create_code):" \
                "$(cat "$tmp_create" 2>/dev/null || echo '(no body)')"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Function: configure_project_settings
# ---------------------------------------------------------------------------
configure_project_settings() {
    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would set new code definition to 'previous version' for $PROJECT_KEY"
        return
    fi

    for setting_key in sonar.leak.period sonar.leak.period.type; do
        local status
        local curl_exit=0
        set +e
        status="$(curl -sS --connect-timeout 10 --max-time 30 \
            -o /dev/null -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $TOKEN" \
            --data-urlencode "component=$PROJECT_KEY" \
            --data-urlencode "key=$setting_key" \
            --data-urlencode "value=previous_version" \
            "$SERVER_URL/api/settings/set")"
        curl_exit=$?
        set -e
        if [[ "$curl_exit" -ne 0 ]]; then
            log_info "Could not reach SonarQube Cloud to set project settings. Non-critical — continuing."
            return
        fi

        case "$status" in
            200|204) ;;
            403)
                log_info "Could not set new code definition (HTTP 403). You may lack admin permissions on this project."
                return
                ;;
            *)
                log_info "Could not set new code definition (HTTP $status). Non-critical — continuing."
                return
                ;;
        esac
    done

    log_success "New code definition set to 'previous version'."
}

# ---------------------------------------------------------------------------
# Function: write_config_files
# ---------------------------------------------------------------------------
write_config_files() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    # --- sonar-project.properties ---
    local props_file="$repo_root/sonar-project.properties"
    local props_content="sonar.organization=$ORG_KEY
sonar.projectKey=$PROJECT_KEY"

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would write $props_file with:"
        echo "$props_content" >&2
    elif [[ -f "$props_file" ]] && [[ "$FORCE" != true ]]; then
        log_info "sonar-project.properties already exists (use --force to overwrite)."
    else
        local verb="Created"
        [[ -f "$props_file" ]] && verb="Overwritten"
        echo "$props_content" > "$props_file"
        log_success "sonar-project.properties ${verb}."
    fi

    # --- .sonarlint/connectedMode.json ---
    local sonarlint_dir="$repo_root/.sonarlint"
    local connected_file="$sonarlint_dir/connectedMode.json"
    local json_content
    json_content="$(jq -n \
        --arg org "$ORG_KEY" \
        --arg key "$PROJECT_KEY" \
        '{sonarCloudOrganization: $org, projectKey: $key}')"

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would write $connected_file with:"
        echo "$json_content" >&2
    elif [[ -f "$connected_file" ]] && [[ "$FORCE" != true ]]; then
        log_info ".sonarlint/connectedMode.json already exists (use --force to overwrite)."
    else
        mkdir -p "$sonarlint_dir"
        local verb="Created"
        [[ -f "$connected_file" ]] && verb="Overwritten"
        echo "$json_content" > "$connected_file"
        log_success ".sonarlint/connectedMode.json ${verb}."
    fi
}

# ---------------------------------------------------------------------------
# Function: ensure_scanner
# ---------------------------------------------------------------------------
ensure_scanner() {
    local local_scanner="$HOME/.sonar/sonar-scanner/bin/sonar-scanner"

    if command -v sonar-scanner > /dev/null 2>&1; then
        SCANNER_CMD="sonar-scanner"
        log_verbose "Found sonar-scanner on PATH."
        log_success "$MSG_SCANNER_READY"
        return
    fi

    if [[ -x "$local_scanner" ]]; then
        SCANNER_CMD="$local_scanner"
        log_verbose "Found sonar-scanner at: $SCANNER_CMD"
        log_success "$MSG_SCANNER_READY"
        return
    fi

    if docker info > /dev/null 2>&1; then
        USE_DOCKER=true
        SCANNER_CMD="docker"
        log_info "Using Docker for sonar-scanner."
        log_success "$MSG_SCANNER_READY"
        return
    fi

    log_info "sonar-scanner not found."

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would download sonar-scanner ${SCANNER_VERSION}."
        SCANNER_CMD="$local_scanner"
        return
    fi

    printf "Would you like to download sonar-scanner? [y/N] " >&2
    local answer
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_error "sonar-scanner is required to run analysis." \
            "Install it manually or ensure Docker is available."
        exit 1
    fi

    local os_name arch_name
    os_name="$(uname -s)"
    arch_name="$(uname -m)"

    local dl_os dl_arch
    case "$os_name" in
        Darwin) dl_os="macosx" ;;
        Linux)  dl_os="linux" ;;
        *)
            log_error "Unsupported OS: $os_name"
            exit 1
            ;;
    esac

    case "$arch_name" in
        x86_64)          dl_arch="x64" ;;
        arm64|aarch64)   dl_arch="aarch64" ;;
        *)
            log_error "Unsupported architecture: $arch_name"
            exit 1
            ;;
    esac

    local url="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SCANNER_VERSION}-${dl_os}-${dl_arch}.zip"
    log_info "Downloading sonar-scanner from $url ..."

    local zip_file
    zip_file="$(mktmp)"
    local curl_exit=0
    set +e
    curl -fSL --connect-timeout 10 --max-time 300 -o "$zip_file" "$url"
    curl_exit=$?
    set -e
    if [[ "$curl_exit" -ne 0 ]]; then
        log_error "Failed to download sonar-scanner (curl exit $curl_exit)." \
            "Check your network connection and try again."
        exit 1
    fi

    local sha_url="${url}.sha256"
    local expected_sha=""
    set +e
    expected_sha="$(curl -fsSL --connect-timeout 10 --max-time 15 "$sha_url" | awk '{print $1}')"
    set -e
    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        if command -v sha256sum > /dev/null 2>&1; then
            actual_sha="$(sha256sum "$zip_file" | awk '{print $1}')"
        else
            actual_sha="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
        fi
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_error "Checksum mismatch for sonar-scanner download." \
                "Expected: $expected_sha" \
                "Got:      $actual_sha" \
                "The download may be corrupted. Try again or install manually."
            exit 1
        fi
        log_verbose "Checksum verified."
    else
        log_verbose "Could not fetch checksum file — skipping verification."
    fi

    rm -rf "$HOME/.sonar/sonar-scanner/"
    unzip -qo "$zip_file" -d "$HOME/.sonar/"

    local extracted_dir=""
    for extracted_dir in "$HOME/.sonar/sonar-scanner-cli-${SCANNER_VERSION}-"*/; do
        break
    done
    if [[ ! -d "$extracted_dir" ]]; then
        log_error "Scanner zip did not extract as expected." \
            "Check the contents of $HOME/.sonar/ and try installing manually."
        exit 1
    fi
    mv "$extracted_dir" "$HOME/.sonar/sonar-scanner/"

    if [[ "$os_name" = "Darwin" ]]; then
        xattr -dr com.apple.quarantine "$HOME/.sonar/sonar-scanner/" 2>/dev/null || true
    fi

    SCANNER_CMD="$local_scanner"

    if ! "$SCANNER_CMD" --version > /dev/null 2>&1; then
        log_error "sonar-scanner installation failed — binary not working."
        exit 1
    fi

    log_success "$MSG_SCANNER_READY"
}

# ---------------------------------------------------------------------------
# Function: run_scan
# ---------------------------------------------------------------------------
run_scan() {
    export SONAR_TOKEN="$TOKEN"
    export SONAR_HOST_URL="$SERVER_URL"

    local project_root
    project_root="$(git rev-parse --show-toplevel)"

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would run: $SCANNER_CMD"
        return 0
    fi

    log_info "Running SonarQube analysis... (this may take a few minutes)"

    local scan_exit=0
    local tmp_output
    tmp_output="$(mktmp)"

    if [[ "$USE_DOCKER" = true ]]; then
        local -a docker_cmd=(
            docker run --rm
            -e SONAR_TOKEN -e SONAR_HOST_URL
            -v "${project_root}:/usr/src"
            sonarsource/sonar-scanner-cli
        )

        if [[ "$VERBOSE" = true ]]; then
            set +e
            "${docker_cmd[@]}" 2>&1 | tee "$tmp_output"
            scan_exit=${PIPESTATUS[0]}
            set -e
        else
            set +e
            "${docker_cmd[@]}" > "$tmp_output" 2>&1 &
            local scan_pid=$!
            while kill -0 "$scan_pid" 2>/dev/null; do
                printf "." >&2
                sleep 2
            done
            wait "$scan_pid"
            scan_exit=$?
            set -e
            echo >&2
        fi
    else
        if [[ "$VERBOSE" = true ]]; then
            set +e
            (cd "$project_root" && "$SCANNER_CMD") 2>&1 | tee "$tmp_output"
            scan_exit=${PIPESTATUS[0]}
            set -e
        else
            set +e
            (cd "$project_root" && "$SCANNER_CMD") > "$tmp_output" 2>&1 &
            local scan_pid=$!
            while kill -0 "$scan_pid" 2>/dev/null; do
                printf "." >&2
                sleep 2
            done
            wait "$scan_pid"
            scan_exit=$?
            set -e
            echo >&2
        fi
    fi

    case "$scan_exit" in
        0)
            log_success "Analysis complete."
            return 0
            ;;
        2)
            local output
            output="$(cat "$tmp_output")"
            if echo "$output" | grep -qi "Not authorized"; then
                log_error "Authentication failed." \
                    "Check that your token has 'Execute Analysis' permission." \
                    "Generate a new token at: $SERVER_URL/account/security"
            elif echo "$output" | grep -qi "Automatic Analysis is enabled"; then
                log_error "Automatic analysis is enabled for this project." \
                    "Disable it at: $SERVER_URL/project/administration?id=$PROJECT_KEY (Analysis Method section)" \
                    "Then re-run apply-sonar."
            elif echo "$output" | grep -qi "OutOfMemoryError"; then
                log_error "Scanner ran out of memory." \
                    "Re-run with: SONAR_SCANNER_JAVA_OPTS='-Xmx4g' apply-sonar"
            else
                echo "${_color_red}[ERROR]${_color_reset} Scanner failed. Last 20 lines of output:" >&2
                tail -20 "$tmp_output" >&2
            fi
            exit 2
            ;;
        1)
            log_error "Scanner encountered an internal error." \
                "Re-run with --verbose for full output."
            exit 1
            ;;
        *)
            log_error "Scanner exited with code $scan_exit." \
                "Re-run with --verbose for full output."
            exit "$scan_exit"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Function: show_results
# ---------------------------------------------------------------------------
show_results() {
    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would fetch quality gate status and show summary."
        return
    fi

    # Allow SonarQube Cloud a moment to finalize the analysis report.
    sleep 3

    local gate_response gate_status display_status
    gate_response="$(curl -sS --connect-timeout 10 --max-time 30 \
        -H "Authorization: Bearer $TOKEN" \
        "$SERVER_URL/api/qualitygates/project_status?projectKey=$PROJECT_KEY" 2>/dev/null || true)"

    gate_status="$(echo "$gate_response" | jq -r '.projectStatus.status // empty' 2>/dev/null || true)"

    case "$gate_status" in
        OK)    display_status="Passed" ;;
        ERROR) display_status="Failed" ;;
        NONE)  display_status="Not Computed — normal for a first scan. Push a change and scan again to see results." ;;
        WARN)  display_status="Warning" ;;
        *)     display_status="Unknown" ;;
    esac

    local border_color="$_color_reset"
    if [[ -t 2 ]]; then
        case "$gate_status" in
            OK)    border_color="$_color_green" ;;
            ERROR) border_color="$_color_red" ;;
            *)     border_color="$_color_yellow" ;;
        esac
    fi

    local dashboard_url="$SERVER_URL/project/overview?id=$PROJECT_KEY"

    cat >&2 <<EOF

${border_color}══════════════════════════════════════════════════════${_color_reset}
SonarQube Cloud setup complete!

Project:       $PROJECT_NAME
Dashboard:     $dashboard_url
Quality Gate:  $display_status

Config files:
  sonar-project.properties
  .sonarlint/connectedMode.json

Next steps:
  • View your project: $dashboard_url
  • The quality gate evaluates on your next code change
  • Add SONAR_TOKEN to your CI secrets for automated scanning
${border_color}══════════════════════════════════════════════════════${_color_reset}
EOF
}

# ---------------------------------------------------------------------------
# Function: maybe_integrate_claude
# ---------------------------------------------------------------------------
maybe_integrate_claude() {
    if [[ "$INTEGRATE_CLAUDE" != true ]]; then
        return
    fi

    if ! "$SONAR_CLI" integrate claude --help > /dev/null 2>&1; then
        log_info "sonar CLI does not support 'integrate claude' — skipping."
        return
    fi

    if [[ "$DRY_RUN" = true ]]; then
        log_dryrun "Would run: sonar integrate claude -p $PROJECT_KEY"
        return
    fi

    local integrate_exit=0
    set +e
    "$SONAR_CLI" integrate claude -p "$PROJECT_KEY"
    integrate_exit=$?
    set -e

    if [[ "$integrate_exit" -eq 0 ]]; then
        log_success "Claude Code integration configured."
    else
        log_info "Claude integration failed (exit $integrate_exit). You can run it manually:"
        echo "        sonar integrate claude -p $PROJECT_KEY" >&2
    fi
}

# ---------------------------------------------------------------------------
# Function: main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_prerequisites
    if [[ -z "$TOKEN" ]] || [[ -z "$ORG_KEY" ]] || [[ "$INTEGRATE_CLAUDE" = true ]]; then
        ensure_sonar_cli
    fi
    ensure_auth
    detect_project_info
    ensure_project_exists
    configure_project_settings
    write_config_files
    ensure_scanner
    run_scan
    show_results
    maybe_integrate_claude
    exit 0
}

main "$@"
