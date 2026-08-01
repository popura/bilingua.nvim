#!/usr/bin/env sh
set -eu

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex CLI is required" >&2
  exit 1
fi

schema_dir=$(mktemp -d "${TMPDIR:-/tmp}/bilingua-codex-schema.XXXXXX")
trap 'rm -rf -- "$schema_dir"' EXIT HUP INT TERM

codex app-server generate-json-schema --out "$schema_dir"

required_files="
v1/InitializeParams.json
v2/ModelListParams.json
v2/ThreadStartParams.json
v2/ThreadStartResponse.json
v2/TurnStartParams.json
v2/TurnStartResponse.json
v2/TurnInterruptParams.json
v2/ItemCompletedNotification.json
v2/TurnCompletedNotification.json
v2/ThreadUnsubscribeParams.json
ServerRequest.json
codex_app_server_protocol.schemas.json
codex_app_server_protocol.v2.schemas.json
"

for relative_path in $required_files; do
  if [ ! -f "$schema_dir/$relative_path" ]; then
    echo "error: missing Codex schema: $relative_path" >&2
    exit 1
  fi
done

require_field() {
  relative_path=$1
  field=$2
  needle='"'$field'"'
  if ! grep -Fq "$needle" "$schema_dir/$relative_path"; then
    echo "error: Codex schema $relative_path no longer exposes required field: $field" >&2
    exit 1
  fi
}

require_method() {
  method=$1
  needle='"'$method'"'
  if ! grep -Fq "$needle" "$schema_dir/ServerRequest.json"; then
    echo "error: Codex schema no longer exposes required server request: $method" >&2
    exit 1
  fi
}

require_field v1/InitializeParams.json clientInfo
require_field v1/InitializeParams.json capabilities
require_field v2/ModelListParams.json cursor
require_field v2/ThreadStartParams.json ephemeral
require_field v2/ThreadStartParams.json developerInstructions
require_field v2/ThreadStartParams.json approvalPolicy
require_field v2/ThreadStartParams.json sandbox
require_field v2/ThreadStartResponse.json instructionSources
require_field v2/ThreadStartResponse.json ephemeral
require_field v2/TurnStartParams.json threadId
require_field v2/TurnStartParams.json input
require_field v2/TurnStartParams.json approvalPolicy
require_field v2/TurnStartParams.json sandboxPolicy
require_field v2/TurnStartParams.json outputSchema
require_field v2/TurnStartResponse.json turn
require_field v2/TurnInterruptParams.json threadId
require_field v2/TurnInterruptParams.json turnId
require_field v2/ItemCompletedNotification.json item
require_field v2/TurnCompletedNotification.json turn
require_field v2/ThreadUnsubscribeParams.json threadId

require_method item/commandExecution/requestApproval
require_method item/fileChange/requestApproval
require_method item/permissions/requestApproval
require_method mcpServer/elicitation/request
require_method item/tool/requestUserInput

echo "Codex app-server schema exposes every method and field required by Bilingua.nvim."
