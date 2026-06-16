#!/usr/bin/env bash
# platform_explorer_api.sh — общий доступ к platform-explorer API.
#
# Локально (platformExp, localhost:3005):
#   export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"
#
# BigBr (109): нет локального platform-explorer — внешний API
#   export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"
#
# platformExp (161): локальный platform-explorer
#   export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"

platform_explorer_resolve_url() {
	if [[ -z "${PLATFORM_EXPLORER_URL:-}" ]]; then
		PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"
	fi
}

platform_explorer_api_label() {
	platform_explorer_resolve_url
	if [[ -n "${PLATFORM_EXPLORER_SSH:-}" ]]; then
		echo "${PLATFORM_EXPLORER_SSH} → ${PLATFORM_EXPLORER_URL}"
	else
		echo "$PLATFORM_EXPLORER_URL"
	fi
}

# GET path (e.g. /status, /epoch/72, /validator/HASH)
platform_api_get() {
	local path="$1"
	local url

	platform_explorer_resolve_url
	path="${path#/}"
	url="${PLATFORM_EXPLORER_URL%/}/${path}"

	if [[ -n "${PLATFORM_EXPLORER_SSH:-}" ]]; then
		ssh -o BatchMode=yes -o ConnectTimeout=15 "$PLATFORM_EXPLORER_SSH" \
			"curl -sf --max-time 20 $(printf '%q' "$url")"
	else
		curl -sf --max-time 20 "$url"
	fi
}
