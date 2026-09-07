#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT_USERNAME="$1"
DISPLAY_NAME="$2"
DEPARTMENT="$3"
JOB_TITLE="$4"

if [ -z "$INPUT_USERNAME" ] || [ -z "$DISPLAY_NAME" ] || [ -z "$DEPARTMENT" ] || [ -z "$JOB_TITLE" ]; then
  echo "Usage: ./joiner.sh <username> <displayName> <department> <jobTitle>"
  exit 1
fi

if [ -z "$TENANT_ID" ] || [ -z "$CLIENT_ID" ]; then
  echo "Missing required environment variables."
  exit 1
fi

DOMAIN="AutumnSolutionsoutlook.onmicrosoft.com"
USER_UPN="${INPUT_USERNAME}@${DOMAIN}"

LICENSE_SKU_ID="84a661c4-e949-4bd2-a560-ed7766fcaf2b"

ACCESS_TOKEN=$(node "$SCRIPT_DIR/get_graph_token.mjs")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Failed to obtain certificate-authenticated access token."
  exit 1
fi

USER_RESPONSE=$(curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://graph.microsoft.com/v1.0/users/$USER_UPN?\$select=id,displayName,department,jobTitle,userPrincipalName")

if echo "$USER_RESPONSE" | grep -q '"Request_ResourceNotFound"'; then
  echo "User does not exist. Creating account..."

  TEMP_PASSWORD="Autumn!$(date +%s)Aa9"

  CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"accountEnabled\": true,
      \"displayName\": \"$DISPLAY_NAME\",
      \"mailNickname\": \"$INPUT_USERNAME\",
      \"userPrincipalName\": \"$USER_UPN\",
      \"department\": \"$DEPARTMENT\",
      \"jobTitle\": \"$JOB_TITLE\",
      \"usageLocation\": \"US\",
      \"passwordProfile\": {
        \"forceChangePasswordNextSignIn\": true,
        \"password\": \"$TEMP_PASSWORD\"
      }
    }" \
    "https://graph.microsoft.com/v1.0/users")

  HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n 1)
  USER_RESPONSE=$(echo "$CREATE_RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" != "201" ]; then
    echo "Failed to create user. HTTP $HTTP_CODE"
    echo "$USER_RESPONSE"
    exit 1
  fi

  echo "Created $DISPLAY_NAME"
else
  echo "User already exists. Continuing with access provisioning."
fi

USER_ID=$(echo "$USER_RESPONSE" | sed -E 's/.*"id":"([^"]+)".*/\1/')

ensure_usage_location() {
  USER_STATE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/users/$USER_ID?\$select=usageLocation")

  if echo "$USER_STATE" | grep -q '"usageLocation":"US"'; then
    echo "Usage location already set to US"
    return
  fi

  HTTP_CODE=$(curl -s -o /tmp/graph_usage_response.txt -w "%{http_code}" \
    -X PATCH \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"usageLocation":"US"}' \
    "https://graph.microsoft.com/v1.0/users/$USER_ID")

  if [ "$HTTP_CODE" = "204" ]; then
    echo "Set usage location to US"

    echo "Waiting for usage location to become available for licensing..."

    for attempt in {1..10}; do
      USER_STATE=$(curl -s         -H "Authorization: Bearer $ACCESS_TOKEN"         "https://graph.microsoft.com/v1.0/users/$USER_ID?\$select=usageLocation")

      if echo "$USER_STATE" | grep -q '"usageLocation":"US"'; then
        echo "Usage location verified"
        break
      fi

      sleep 2
    done

    if ! echo "$USER_STATE" | grep -q '"usageLocation":"US"'; then
      echo "Usage location did not become available in time."
      exit 1
    fi
  else
    echo "Failed to set usage location. HTTP $HTTP_CODE"
    cat /tmp/graph_usage_response.txt
    exit 1
  fi
}

assign_license() {
  LICENSE_STATE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/users/$USER_ID?\$select=assignedLicenses")

  if echo "$LICENSE_STATE" | grep -q "$LICENSE_SKU_ID"; then
    echo "Microsoft Entra ID P2 license already assigned"
    return 0
  fi

  for ATTEMPT in 1 2 3 4 5; do
    HTTP_CODE=$(curl -s -o /tmp/graph_license_response.txt -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"addLicenses\":[{\"skuId\":\"$LICENSE_SKU_ID\"}],\"removeLicenses\":[]}" \
      "https://graph.microsoft.com/v1.0/users/$USER_ID/assignLicense")

    if [ "$HTTP_CODE" = "200" ]; then
      echo "Assigned Microsoft Entra ID P2 license"
      return 0
    fi

    if [ "$HTTP_CODE" = "400" ] && grep -qi "invalid usage location" /tmp/graph_license_response.txt; then
      echo "Licensing service not ready yet. Retry $ATTEMPT of 5..."
      sleep 4
      continue
    fi

    echo "Failed to assign license. HTTP $HTTP_CODE"
    cat /tmp/graph_license_response.txt
    return 1
  done

  echo "Failed to assign license after 5 attempts."
  cat /tmp/graph_license_response.txt
  return 1
}

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

get_group_id() {
  GROUP_NAME="$1"

  GROUP_RESPONSE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/groups?\$filter=displayName%20eq%20'$GROUP_NAME'&\$select=id")

  echo "$GROUP_RESPONSE" | sed -E 's/.*"id":"([^"]+)".*/\1/'
}

is_member() {
  GROUP_ID="$1"

  RESPONSE=$(curl -s \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/members?\$select=id")

  echo "$RESPONSE" | grep -q "\"id\":\"$USER_ID\""
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
echo "Processing joiner:"
echo "$DISPLAY_NAME"
echo "$USER_UPN"
echo "Department: $DEPARTMENT"
echo "Job title: $JOB_TITLE"
echo

TARGET_GROUP_ID=$(get_group_id "$TARGET_GROUP")
ALL_EMPLOYEES_GROUP_ID=$(get_group_id "SG-All-Employees")

add_to_group "$TARGET_GROUP_ID" "$TARGET_GROUP"
add_to_group "$ALL_EMPLOYEES_GROUP_ID" "SG-All-Employees"

ensure_usage_location
assign_license

echo
echo "Joiner workflow complete."
