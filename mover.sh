#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT_USERNAME="$1"

if [ -z "$INPUT_USERNAME" ]; then
  echo "Usage: ./mover.sh <username>"
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

USER_RESPONSE=$(curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://graph.microsoft.com/v1.0/users/$USER_UPN?\$select=id,displayName,department,userPrincipalName")

if echo "$USER_RESPONSE" | grep -q '"error"'; then
  echo "User lookup failed."
  echo "$USER_RESPONSE"
  exit 1
fi

USER_ID=$(echo "$USER_RESPONSE" | sed -E 's/.*"id":"([^"]+)".*/\1/')
DEPARTMENT=$(echo "$USER_RESPONSE" | sed -E 's/.*"department":"([^"]+)".*/\1/')
DISPLAY_NAME=$(echo "$USER_RESPONSE" | sed -E 's/.*"displayName":"([^"]+)".*/\1/')

case "$DEPARTMENT" in
  "Finance") TARGET_GROUP="SG-Finance" ;;
  "Human Resources") TARGET_GROUP="SG-HR" ;;
  "Sales") TARGET_GROUP="SG-Sales" ;;
  "Operations") TARGET_GROUP="SG-Operations" ;;
  "Information Technology") TARGET_GROUP="SG-IT" ;;
  *)
    echo "No group mapping found for department: $DEPARTMENT"
    exit 1
    ;;
esac

DEPT_GROUPS=("SG-Finance" "SG-HR" "SG-Sales" "SG-Operations" "SG-IT")

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
    "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members?\$select=id")

  echo "$RESPONSE" | grep -q "\"id\":\"$USER_ID\""
}

remove_from_group() {
  GROUP_ID="$1"
  GROUP_NAME="$2"

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

add_to_group() {
  GROUP_ID="$1"
  GROUP_NAME="$2"

  if is_member "$GROUP_ID"; then
    echo "$DISPLAY_NAME is already a member of $GROUP_NAME"
    return
  fi

  HTTP_CODE=$(curl -s -o /tmp/graph_response.txt -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"@odata.id\":\"https://graph.microsoft.com/v1.0/directoryObjects/$USER_ID\"}" \
    "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members/\$ref")

  if [ "$HTTP_CODE" = "204" ]; then
    echo "Added $DISPLAY_NAME to $GROUP_NAME"
  else
    echo "Failed to add $DISPLAY_NAME to $GROUP_NAME"
    cat /tmp/graph_response.txt
  fi
}

echo
echo "Processing mover:"
echo "$DISPLAY_NAME"
echo "$USER_UPN"
echo "New department: $DEPARTMENT"
echo

for GROUP_NAME in "${DEPT_GROUPS[@]}"; do
  GROUP_ID=$(get_group_id "$GROUP_NAME")

  if [ "$GROUP_NAME" = "$TARGET_GROUP" ]; then
    add_to_group "$GROUP_ID" "$GROUP_NAME"
  else
    if is_member "$GROUP_ID"; then
      remove_from_group "$GROUP_ID" "$GROUP_NAME"
    fi
  fi
done

ALL_EMPLOYEES_GROUP_ID=$(get_group_id "SG-All-Employees")
add_to_group "$ALL_EMPLOYEES_GROUP_ID" "SG-All-Employees"

echo
echo "Mover workflow complete."
