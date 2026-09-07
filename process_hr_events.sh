#!/bin/zsh

BASE_DIR="$HOME/Documents/Autumn-Solutions/Project-03-Identity-Lifecycle-Automation"
CSV_FILE="$BASE_DIR/hr_events.csv"
DOMAIN="AutumnSolutionsoutlook.onmicrosoft.com"

sync_hr_source() {
  if [ -z "$HR_SOURCE_URL" ]; then
    echo "HR_SOURCE_URL is not set."
    exit 1
  fi

  TEMP_HR_FILE="$BASE_DIR/.hr_events.download"

  if ! curl -fL -sS "$HR_SOURCE_URL" -o "$TEMP_HR_FILE"; then
    echo "Failed to download HR source feed."
    rm -f "$TEMP_HR_FILE"
    exit 1
  fi

  HEADER=$(head -n 1 "$TEMP_HR_FILE" | tr -d '\r')

  if [ "$HEADER" != "username,displayName,department,jobTitle,event" ]; then
    echo "HR source validation failed. Unexpected CSV header:"
    echo "$HEADER"
    rm -f "$TEMP_HR_FILE"
    exit 1
  fi

  mv "$TEMP_HR_FILE" "$CSV_FILE"
  echo "HR source synchronized from Google Sheets."
}

sync_hr_source

LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/lifecycle-audit.csv"

mkdir -p "$LOG_DIR"

if [ ! -f "$LOG_FILE" ]; then
  echo "timestamp,event,username,result,message" > "$LOG_FILE"
fi

log_event() {
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  EVENT_TYPE="$1"
  LOG_USERNAME="$2"
  RESULT="$3"
  MESSAGE="$4"

  echo "$TIMESTAMP,$EVENT_TYPE,$LOG_USERNAME,$RESULT,$MESSAGE" >> "$LOG_FILE"
}

if [ ! -f "$CSV_FILE" ]; then
  echo "HR events file not found: $CSV_FILE"
  exit 1
fi

if [ -z "$TENANT_ID" ] || [ -z "$CLIENT_ID" ]; then
  echo "Missing required environment variables."
  exit 1
fi

ACCESS_TOKEN=$(node "$BASE_DIR/get_graph_token.mjs")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Failed to obtain certificate-authenticated access token."
  exit 1
fi

tail -n +2 "$CSV_FILE" | while IFS=',' read -r INPUT_USERNAME DISPLAY_NAME DEPARTMENT JOB_TITLE EVENT || [ -n "$INPUT_USERNAME" ]
do
  INPUT_USERNAME=$(echo "$INPUT_USERNAME" | tr -d '\r')
  DISPLAY_NAME=$(echo "$DISPLAY_NAME" | tr -d '\r')
  DEPARTMENT=$(echo "$DEPARTMENT" | tr -d '\r')
  JOB_TITLE=$(echo "$JOB_TITLE" | tr -d '\r')
  EVENT=$(echo "$EVENT" | tr -d '\r')

  USER_UPN="${INPUT_USERNAME}@${DOMAIN}"

  echo
  echo "Processing HR event:"
  echo "User: $INPUT_USERNAME"
  echo "Display name: $DISPLAY_NAME"
  echo "Department: $DEPARTMENT"
  echo "Job title: $JOB_TITLE"
  echo "Event: $EVENT"

  case "$EVENT" in
    "Joiner")

      if "$BASE_DIR/joiner.sh" \
        "$INPUT_USERNAME" \
        "$DISPLAY_NAME" \
        "$DEPARTMENT" \
        "$JOB_TITLE"; then

        log_event "Joiner" "$INPUT_USERNAME" "SUCCESS" "Joiner workflow completed"
      else
        log_event "Joiner" "$INPUT_USERNAME" "FAILED" "Joiner workflow failed"
      fi

      ;;

    "Mover")
      PATCH_BODY="{\"department\":\"$DEPARTMENT\",\"jobTitle\":\"$JOB_TITLE\"}"

      HTTP_CODE=$(curl -s \
        -o /tmp/hr_patch_response.txt \
        -w "%{http_code}" \
        -X PATCH \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PATCH_BODY" \
        "https://graph.microsoft.com/v1.0/users/$USER_UPN")

      if [ "$HTTP_CODE" != "204" ]; then
        echo "Failed to update Entra attributes. HTTP $HTTP_CODE"
        cat /tmp/hr_patch_response.txt
        echo
        log_event "Mover" "$INPUT_USERNAME" "FAILED" "Entra attribute update failed"
        continue
      fi

      echo "Updated Entra attributes"

      VERIFIED="no"

      for ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
        VERIFY_RESPONSE=$(curl -s \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          "https://graph.microsoft.com/v1.0/users/$USER_UPN?\$select=department,jobTitle")

        CURRENT_DEPARTMENT=$(echo "$VERIFY_RESPONSE" | sed -E 's/.*"department":"([^"]+)".*/\1/')
        CURRENT_JOB_TITLE=$(echo "$VERIFY_RESPONSE" | sed -E 's/.*"jobTitle":"([^"]+)".*/\1/')

        echo "Verification attempt $ATTEMPT: department=<$CURRENT_DEPARTMENT> jobTitle=<$CURRENT_JOB_TITLE>"

        if [ "$CURRENT_DEPARTMENT" = "$DEPARTMENT" ] && [ "$CURRENT_JOB_TITLE" = "$JOB_TITLE" ]; then
          VERIFIED="yes"
          echo "Verified department: $CURRENT_DEPARTMENT"
          echo "Verified job title: $CURRENT_JOB_TITLE"
          break
        fi

        sleep 3
      done

      if [ "$VERIFIED" != "yes" ]; then
        echo "Attribute verification failed after 10 attempts."
        log_event "Mover" "$INPUT_USERNAME" "FAILED" "Attribute verification failed"
        continue
      fi
      if "$BASE_DIR/mover.sh" "$INPUT_USERNAME"; then
        log_event "Mover" "$INPUT_USERNAME" "SUCCESS" "Mover workflow completed"
      else
        log_event "Mover" "$INPUT_USERNAME" "FAILED" "Mover workflow failed"
      fi

      ;;

    "Leaver")

      if "$BASE_DIR/leaver.sh" "$INPUT_USERNAME"; then
        log_event "Leaver" "$INPUT_USERNAME" "SUCCESS" "Leaver workflow completed"
      else
        log_event "Leaver" "$INPUT_USERNAME" "FAILED" "Leaver workflow failed"
      fi

      ;;

    *)

      echo "Unknown event type: $EVENT"
      log_event "$EVENT" "$INPUT_USERNAME" "FAILED" "Unknown HR event type"

      ;;
  esac
done
