#!/bin/bash
# Delete only the leftover test suites whose name matches
#   FrameScript.<Name>.<UUID>
# strictly. Anything else (the real app domain, FrameScriptTests.*, review
# scratch domains, other apps) is ignored.
#
# Default is a dry run. Add --apply to actually delete.
set -euo pipefail

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=1
elif [[ "${1:-}" == "--dry-run" || -z "${1:-}" ]]; then
    APPLY=0
else
    echo "usage: $0 [--dry-run|--apply]" >&2
    exit 2
fi

PREFERENCES_DIR="$HOME/Library/Preferences"
UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
PATTERN="^FrameScript\\.[A-Za-z0-9_-]+\\.${UUID}$"

DOMAINS=()
while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    if [[ "$domain" =~ $PATTERN ]]; then
        DOMAINS+=("$domain")
    fi
done < <(defaults domains | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

# Include plists that cfprefsd has already forgotten.
if [[ -d "$PREFERENCES_DIR" ]]; then
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        name="$(basename "$file" .plist)"
        if [[ "$name" =~ $PATTERN ]]; then
            DOMAINS+=("$name")
        fi
    done < <(find "$PREFERENCES_DIR" -maxdepth 1 -type f -name 'FrameScript.*.plist' 2>/dev/null)
fi

# Unique + stable order.
SORTED=()
while IFS= read -r domain; do
    [[ -n "$domain" ]] && SORTED+=("$domain")
done < <(printf '%s\n' "${DOMAINS[@]:-}" | sed '/^$/d' | sort -u)

COUNT=${#SORTED[@]}
echo "Matched $COUNT leftover FrameScript.<Name>.<UUID> test suite(s)."

for domain in "${SORTED[@]}"; do
    plist="$PREFERENCES_DIR/$domain.plist"
    if [[ $APPLY -eq 1 ]]; then
        echo "deleting domain: $domain"
        defaults delete "$domain" >/dev/null 2>&1 || true
        if [[ -f "$plist" ]]; then
            echo "deleting plist:  $plist"
            rm -f "$plist"
        fi
    else
        echo "would delete domain: $domain"
        if [[ -f "$plist" ]]; then
            echo "would delete plist:  $plist"
        fi
    fi
done

if [[ $APPLY -eq 1 ]]; then
    echo "Deleted $COUNT suite(s)."
else
    echo "Dry run only. Re-run with --apply to delete them."
fi
