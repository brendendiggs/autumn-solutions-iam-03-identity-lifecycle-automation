#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT_USERNAME="$1"

if [ -z "$INPUT_USERNAME" ]; then
  echo "Usage: ./leaver.sh <username>"
  exit 1
fi

if [ -z "$TENANT_ID" ] || [ -z "$CLIENT_ID" ]; then
  echo "Missing required environment variables."
  exit 1
fi

ACCESS_TOKEN=$(node "$SCRIPT_DIR/get_graph_token.mjs")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Failed to obtain certificate-authenticated access token."
  exit 1
fi

USER_UPN="${INPUT_USERNAME}@AutumnSolutionsoutlook.onmicrosoft.com"
LICENSE_SKU_ID="84a661c4-e949-4bd2-a560-ed7766fcaf2b"

USER_RESPONSE=$(curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://graph.microsoft.com/v1.0/users/$USER_UPN?\$select=id,displayName,userPrincipalName,accountEnabled")

if echo "$USER_RESPONSE" | grep -q '"error"'; then
  echo "User lookup failed."
  echo "$USER_RESPONSE"
  exit 1
fi

USER_ID=$(echo "$USER_RESPONSE" | sed -E 's/.*"id":"([^"]+)".*/\1/')
DISPLAY_NAME=$(echo "$USER_RESPONSE" | sed -E 's/.*"displayName":"([^"]+)".*/\1/')

get_group_id() {
  GROUP_NAME="$1"

  GROUP_RESPONSE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/groups?\$filter=displayName%20eq%20'$GROUP_NAME'&\$select=id,displayName")

  echo "$GROUP_RESPONSE" | sed -E 's/.*"id":"([^"]+)".*/\1/'
}

is_member() {
  GROUP_ID="$1"

  RESPONSE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members/$USER_ID")

  echo "$RESPONSE" | grep -q '"id"'
}

remove_from_group() {
  GROUP_ID="$1"
  GROUP_NAME="$2"

  if ! is_member "$GROUP_ID"; then
    echo "$DISPLAY_NAME is not a member of $GROUP_NAME"
    return
  fi

  HTTP_CODE=$(curl -s -o /tmp/graph_response.txt -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members/$USER_ID/\$ref")

  if [ "$HTTP_CODE" = "204" ]; then
    echo "Removed $DISPLAY_NAME from $GROUP_NAME"
  else
    echo "Failed to remove $DISPLAY_NAME from $GROUP_NAME"
    cat /tmp/graph_response.txt
  fi
}

remove_license() {

  LICENSE_STATE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/users/$USER_ID?\$select=assignedLicenses")

  if ! echo "$LICENSE_STATE" | grep -q "$LICENSE_SKU_ID"; then
    echo "Microsoft Entra ID P2 license is already removed"
    return 0
  fi

  HTTP_CODE=$(curl -s -o /tmp/graph_license_remove_response.txt -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"addLicenses\":[],\"removeLicenses\":[\"$LICENSE_SKU_ID\"]}" \
    "https://graph.microsoft.com/v1.0/users/$USER_ID/assignLicense")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "Removed Microsoft Entra ID P2 license"
    return 0
  fi

  echo "Failed to remove Microsoft Entra ID P2 license. HTTP $HTTP_CODE"
  cat /tmp/graph_license_remove_response.txt
  return 1
}

disable_user() {
  HTTP_CODE=$(curl -s -o /tmp/graph_response.txt -w "%{http_code}" \
    -X PATCH \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"accountEnabled":false}' \
    "https://graph.microsoft.com/v1.0/users/$USER_ID")

  if [ "$HTTP_CODE" = "204" ]; then
    echo "Disabled account for $DISPLAY_NAME"
  else
    echo "Failed to disable account for $DISPLAY_NAME"
    cat /tmp/graph_response.txt
  fi
}

GROUPS_TO_REMOVE=(
  "SG-Finance"
  "SG-HR"
  "SG-Sales"
  "SG-Operations"
  "SG-IT"
  "SG-All-Employees"
)

echo
echo "Processing leaver:"
echo "$DISPLAY_NAME"
echo "$USER_UPN"
echo

for GROUP_NAME in "${GROUPS_TO_REMOVE[@]}"; do
  GROUP_ID=$(get_group_id "$GROUP_NAME")
  remove_from_group "$GROUP_ID" "$GROUP_NAME"
done

remove_license || exit 1

disable_user

echo
echo "Leaver workflow complete."
