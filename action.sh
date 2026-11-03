#!/usr/bin/env bash
# The shell steps of action.yml: `setup` installs redacter and resolves the addons, `run` runs it.
# Inputs arrive as environment variables, never through ${{ }} in a script, so a value cannot
# inject shell code. Kept to bash 3.2, the bash a macOS runner may run it with.
set -euo pipefail

readonly repo="abdolence/redacter-rs"

# A workflow command ends at a new line, so the message is escaped to keep an input value in it
# from starting a command of its own.
fail() {
    local message="$*"
    message=${message//%/%25}
    message=${message//$'\r'/%0D}
    message=${message//$'\n'/%0A}
    printf '::error::%s\n' "$message"
    exit 1
}

list_items() {
    printf '%s\n' "$1" | tr -s ', \t\r\n' '\n' | sed '/^$/d'
}

# Names go into the command line and the cache key, so only lower case words joined by hyphens
# pass. redacter itself checks that the name exists.
check_name() {
    case "$2" in
        "" | -* | *[!a-z0-9-]*) fail "$1 has an invalid name '$2'" ;;
    esac
}

# Hashes standard input rather than the named file: GNU sha256sum puts a backslash before the hash
# of a file whose name holds one, as a Windows path does.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d ' ' -f 1
    else
        shasum -a 256 <"$1" | cut -d ' ' -f 1
    fi
}

setup() {
    case "$INPUT_COMMAND" in
        scan)
            [ -z "$INPUT_DESTINATION" ] || fail "destination is only for the cp command"
            ;;
        cp)
            [ -n "$INPUT_DESTINATION" ] || fail "the cp command needs a destination"
            [ -z "$INPUT_FAIL_ON" ] || fail "fail-on is only for the scan command"
            ;;
        *) fail "command must be scan or cp, got '$INPUT_COMMAND'" ;;
    esac
    command -v jq >/dev/null 2>&1 || fail "jq is not installed on the runner, the action reads the release and the SARIF report with it"

    local asset bin_name
    case "$RUNNER_OS-$RUNNER_ARCH" in
        Linux-X64) asset=redacter-Linux-x86_64.tar.gz bin_name=redacter ;;
        Linux-ARM64) asset=redacter-Linux-aarch64.tar.gz bin_name=redacter ;;
        macOS-ARM64) asset=redacter-Darwin-aarch64.tar.gz bin_name=redacter ;;
        Windows-X64) asset=redacter-Windows-x86_64.zip bin_name=redacter.exe ;;
        *) fail "$RUNNER_OS $RUNNER_ARCH runners are not supported. Supported: Linux X64 and ARM64, macOS ARM64, Windows X64" ;;
    esac

    local version=${INPUT_VERSION#v}
    case "$version" in
        "" | [!0-9]* | *[!0-9A-Za-z.+-]*) fail "version must be a redacter release such as 0.22.0, got '$INPUT_VERSION'" ;;
    esac

    local redacters="" redacter
    while IFS= read -r redacter; do
        check_name redacters "$redacter"
        redacters="${redacters:+$redacters,}$redacter"
    done < <(list_items "$INPUT_REDACTERS")
    [ -n "$redacters" ] || fail "redacters needs at least one redacter"

    local addons addon
    case "$INPUT_ADDONS" in
        auto)
            addons="ocr pdf"
            for addon in local-ner local-gliner local-credential-ml; do
                case ",$redacters," in
                    *",$addon,"*) addons="$addons $addon" ;;
                esac
            done
            ;;
        none) addons="" ;;
        *) addons=$INPUT_ADDONS ;;
    esac
    local resolved_addons=""
    while IFS= read -r addon; do
        check_name addons "$addon"
        resolved_addons="${resolved_addons:+$resolved_addons,}$addon"
    done < <(list_items "$addons" | sort -u)

    local tag="v$version" work_dir
    work_dir=$(mktemp -d "$RUNNER_TEMP/redacter.XXXXXX")
    local release_url="https://api.github.com/repos/$repo/releases/tags/$tag"
    # The token reaches curl as a config on standard input, which keeps it off the command line
    # that other users of a self-hosted runner can read.
    if [ -n "$GITHUB_API_TOKEN" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_API_TOKEN"
    fi | curl -fsSL --retry 3 -K - -H 'Accept: application/vnd.github+json' -o "$work_dir/release.json" "$release_url" ||
        fail "cannot read release $tag from $release_url"

    local expected
    expected=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$work_dir/release.json" | tr -d '\r')
    [[ $expected =~ ^sha256:[0-9a-f]{64}$ ]] || fail "release $tag has no SHA-256 digest for $asset, refusing to install it"
    expected=${expected#sha256:}

    local archive="$work_dir/$asset"
    curl -fsSL --retry 3 -o "$archive" "https://github.com/$repo/releases/download/$tag/$asset" ||
        fail "cannot download $asset of release $tag"
    local actual
    actual=$(sha256_of "$archive")
    [ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $asset: expected $expected, got $actual. Nothing was installed"

    case "$asset" in
        *.zip) unzip -q "$archive" "$bin_name" -d "$work_dir" ;;
        *) tar -xzf "$archive" -C "$work_dir" "$bin_name" ;;
    esac
    echo "Installed redacter $tag from $asset"

    {
        echo "bin=$work_dir/$bin_name"
        echo "addons=$resolved_addons"
        if [ -n "$resolved_addons" ]; then
            echo "addons-dir=$RUNNER_TEMP/redacter-addons"
            echo "addons-cache-key=redacter-addons-$RUNNER_OS-$RUNNER_ARCH-$version-${resolved_addons//,/+}"
        fi
    } >>"$GITHUB_OUTPUT"
}

# Exits with 0 whatever redacter exits with, after setting the outputs: the next step of the
# action fails on the exit code, so a later step of the job that runs on failure, such as an
# upload of the SARIF report, finds the outputs set.
run() {
    local report_dir
    report_dir=$(mktemp -d "$RUNNER_TEMP/redacter-report.XXXXXX")
    local sarif_file="$report_dir/redacter-$INPUT_COMMAND.sarif"

    local args=("$INPUT_COMMAND") redacter arg
    while IFS= read -r redacter; do
        args+=(--redact "$redacter")
    done < <(list_items "$INPUT_REDACTERS")
    if [ -n "$INPUT_CATEGORIES" ]; then
        args+=("--categories=$INPUT_CATEGORIES")
    fi
    if [ -n "$INPUT_FAIL_ON" ]; then
        args+=("--fail-on=$INPUT_FAIL_ON")
    fi
    args+=(--unsupported-as-text --report-format=sarif "--report-file=$sarif_file")
    while IFS= read -r arg; do
        case "$arg" in
            --show-values | --show-values=*)
                fail "--show-values is not accepted, it writes the values found to the log of the run, which everyone with read access to the repository can see"
                ;;
        esac
        args+=("$arg")
    done < <(printf '%s\n' "$INPUT_ARGS" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
    args+=(-- "$INPUT_PATH")
    if [ "$INPUT_COMMAND" = cp ]; then
        args+=("$INPUT_DESTINATION")
    fi

    if [ -n "$ADDONS_DIR" ]; then
        export REDACTER_ADDONS_DIR="$ADDONS_DIR"
    fi
    local exit_code=0
    "$REDACTER_BIN" "${args[@]}" || exit_code=$?

    echo "exit-code=$exit_code" >>"$GITHUB_OUTPUT"
    if [ -f "$sarif_file" ]; then
        local findings
        findings=$(jq '[.runs[].results[] | select(.level == "error")] | length' "$sarif_file" | tr -d '\r')
        printf 'sarif-file=%s\nfindings=%s\n' "$sarif_file" "$findings" >>"$GITHUB_OUTPUT"
    fi
}

case "$1" in
    setup) setup ;;
    run) run ;;
    *) fail "unknown step '$1'" ;;
esac
