#!/usr/bin/env bash
# platform_explorer_api.sh — общий доступ к platform-explorer API.
#
# Локально (platformExp, localhost:3005):
#   export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"
#
# BigBr (109): API на platformExp через SSH (порт 3005 снаружи закрыт):
#   export PLATFORM_EXPLORER_SSH="mno@161.97.96.43"
#   export PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"
#
# Внешний fallback:
#   export PLATFORM_EXPLORER_URL="https://platform-explorer.pshenmic.dev"

platform_explorer_resolve_url() {
	if [[ -z "${PLATFORM_EXPLORER_URL:-}" ]]; then
		if [[ -n "${PLATFORM_EXPLORER_SSH:-}" ]]; then
			PLATFORM_EXPLORER_URL="http://127.0.0.1:3005"
		else
			PLATFORM_EXPLORER_URL="http://localhost:3005"
		fi
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
