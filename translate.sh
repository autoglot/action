#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Autoglot Translate${NC}"
echo "=================="

# Validate inputs
if [ -z "$AUTOGLOT_API_KEY" ]; then
    echo -e "${RED}Error: AUTOGLOT_API_KEY is required${NC}"
    exit 1
fi

if [ -z "$TARGET_LANGUAGES" ]; then
    echo -e "${RED}Error: TARGET_LANGUAGES is required${NC}"
    exit 1
fi

if [ -z "$GITHUB_REPO" ]; then
    echo -e "${RED}Error: GITHUB_REPO is required${NC}"
    exit 1
fi

API_URL="${AUTOGLOT_API_URL:-https://api.autoglot.app}"
BRANCH="${BRANCH_NAME:-autoglot/translations}"
BASE_BRANCH="${GITHUB_BASE_BRANCH:-main}"
COMMIT_MSG="${COMMIT_MESSAGE:-chore(i18n): update translations}"
PR_TITLE_MSG="${PR_TITLE:-chore(i18n): update translations}"
OUTPUT_MODE_VAL="${OUTPUT_MODE:-create-pr}"
HEAD_BRANCH_VAL="${HEAD_BRANCH:-}"
TRIGGER_SHA_VAL="${TRIGGER_SHA:-}"

# Wait for completion defaults to true for commit-to-branch mode
if [ -n "$WAIT_FOR_COMPLETION" ]; then
    WAIT_FOR_COMPLETION_VAL="$WAIT_FOR_COMPLETION"
elif [ "$OUTPUT_MODE_VAL" = "commit-to-branch" ]; then
    WAIT_FOR_COMPLETION_VAL="true"
else
    WAIT_FOR_COMPLETION_VAL="false"
fi

echo "Repository: $GITHUB_REPO"
echo "Output mode: $OUTPUT_MODE_VAL"
if [ "$OUTPUT_MODE_VAL" = "commit-to-branch" ]; then
    if [ -n "$HEAD_BRANCH_VAL" ]; then
        echo "Head branch: $HEAD_BRANCH_VAL"
    else
        echo "Head branch: $BASE_BRANCH (default)"
    fi
else
    echo "Branch: $BRANCH"
fi
echo "Base branch: $BASE_BRANCH"
echo "Languages: $TARGET_LANGUAGES"
echo ""

# Check if this commit was made by autoglot bot (prevent infinite loops)
# When using GitHub App, commits are attributed to autoglot[bot]
# PAT commits don't trigger workflows anyway (GitHub's built-in protection)
COMMIT_AUTHOR=$(git log -1 --pretty=%an 2>/dev/null || echo "")
if echo "$COMMIT_AUTHOR" | grep -qi "autoglot\[bot\]"; then
    echo -e "${YELLOW}Skipping: Commit was made by autoglot bot${NC}"
    echo ""
    echo "This prevents infinite translation loops when autoglot PRs are merged."
    exit 0
fi

# Find translation files
if [ -z "$INPUT_PATHS" ]; then
    echo "Searching for .xcstrings files..."
    FILES=$(find . -name "*.xcstrings" -type f | grep -v "node_modules" | grep -v ".build" | sort)
else
    echo "Searching in paths: $INPUT_PATHS"
    FILES=""

    # Process each path pattern
    for pattern in $INPUT_PATHS; do
        # Find .xcstrings files
        XCSTRINGS=$(find $pattern -name "*.xcstrings" -type f 2>/dev/null | grep -v "node_modules" | grep -v ".build" || echo "")
        if [ -n "$XCSTRINGS" ]; then
            FILES="$FILES"$'\n'"$XCSTRINGS"
        fi

        # Find source language JSON files (en.json only, not translated files)
        JSON_FILES=$(find $pattern -name "en.json" -type f 2>/dev/null | grep -v "node_modules" || echo "")
        if [ -n "$JSON_FILES" ]; then
            FILES="$FILES"$'\n'"$JSON_FILES"
        fi

        # Find source language YAML files (en.yml, en.yaml only)
        YAML_FILES=$(find $pattern \( -name "en.yml" -o -name "en.yaml" \) -type f 2>/dev/null | grep -v "node_modules" || echo "")
        if [ -n "$YAML_FILES" ]; then
            FILES="$FILES"$'\n'"$YAML_FILES"
        fi

        # Find source language PO files (en.po only, not translated files)
        PO_FILES=$(find $pattern -name "en.po" -type f 2>/dev/null | grep -v "node_modules" || echo "")
        if [ -n "$PO_FILES" ]; then
            FILES="$FILES"$'\n'"$PO_FILES"
        fi

        # Find POT template files (messages.pot, etc.)
        POT_FILES=$(find $pattern -name "*.pot" -type f 2>/dev/null | grep -v "node_modules" || echo "")
        if [ -n "$POT_FILES" ]; then
            FILES="$FILES"$'\n'"$POT_FILES"
        fi
    done

    # Clean up empty lines and sort
    FILES=$(echo "$FILES" | grep -v "^$" | sort -u)
fi

if [ -z "$FILES" ]; then
    echo -e "${YELLOW}No translation files found${NC}"
    exit 0
fi

FILE_COUNT=$(echo "$FILES" | wc -l | tr -d ' ')
echo -e "Found ${BLUE}$FILE_COUNT${NC} file(s)"
echo ""

# Create temp directory for payload
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Convert comma-separated languages to JSON array
LANGUAGES_JSON=$(echo "$TARGET_LANGUAGES" | jq -R 'split(",")')

# Build files array for API request using --slurpfile to avoid argument limits
echo -e "${BLUE}Reading files...${NC}"
echo "[]" > "$TEMP_DIR/files.json"

for file in $FILES; do
    echo "  - $file"

    # Strip leading ./ from path (GitHub API doesn't accept paths starting with ./)
    clean_filename="${file#./}"

    # Detect if file is JSON (xcstrings, json) or plain text (po, pot, yaml, yml)
    case "$file" in
        *.xcstrings|*.json)
            # JSON files: use --slurpfile to read as structured JSON
            jq --slurpfile content "$file" \
               --arg filename "$clean_filename" \
               '. + [{"filename": $filename, "content": $content[0]}]' \
               "$TEMP_DIR/files.json" > "$TEMP_DIR/files_new.json"
            ;;
        *)
            # Plain text files (PO, YAML, etc.): read as raw string
            jq --rawfile content "$file" \
               --arg filename "$clean_filename" \
               '. + [{"filename": $filename, "content": $content}]' \
               "$TEMP_DIR/files.json" > "$TEMP_DIR/files_new.json"
            ;;
    esac
    mv "$TEMP_DIR/files_new.json" "$TEMP_DIR/files.json"
done

echo ""
echo -e "${BLUE}Submitting translation job...${NC}"

# Normalize output mode for API (convert kebab-case to snake_case)
API_OUTPUT_MODE="create_pr"
if [ "$OUTPUT_MODE_VAL" = "commit-to-branch" ]; then
    API_OUTPUT_MODE="commit_to_branch"
fi

# Build the full request payload to a file (avoids argument limits for curl)
# Include github_pat only if provided (GitHub App can be used instead)
if [ -n "$GITHUB_PAT" ]; then
    jq -n \
        --slurpfile files "$TEMP_DIR/files.json" \
        --argjson target_languages "$LANGUAGES_JSON" \
        --arg github_repo "$GITHUB_REPO" \
        --arg github_pat "$GITHUB_PAT" \
        --arg github_base_branch "$BASE_BRANCH" \
        --arg branch_name "$BRANCH" \
        --arg commit_message "$COMMIT_MSG" \
        --arg pr_title "$PR_TITLE_MSG" \
        --arg output_mode "$API_OUTPUT_MODE" \
        --arg github_head_branch "$HEAD_BRANCH_VAL" \
        --arg trigger_sha "$TRIGGER_SHA_VAL" \
        '{
            files: $files[0],
            target_languages: $target_languages,
            github_repo: $github_repo,
            github_pat: $github_pat,
            github_base_branch: $github_base_branch,
            branch_name: $branch_name,
            commit_message: $commit_message,
            pr_title: $pr_title,
            output_mode: $output_mode
        } + (if $github_head_branch != "" then {github_head_branch: $github_head_branch} else {} end)
          + (if $trigger_sha != "" then {trigger_sha: $trigger_sha} else {} end)' > "$TEMP_DIR/payload.json"
    echo "  Using provided PAT for GitHub access"
else
    jq -n \
        --slurpfile files "$TEMP_DIR/files.json" \
        --argjson target_languages "$LANGUAGES_JSON" \
        --arg github_repo "$GITHUB_REPO" \
        --arg github_base_branch "$BASE_BRANCH" \
        --arg branch_name "$BRANCH" \
        --arg commit_message "$COMMIT_MSG" \
        --arg pr_title "$PR_TITLE_MSG" \
        --arg output_mode "$API_OUTPUT_MODE" \
        --arg github_head_branch "$HEAD_BRANCH_VAL" \
        --arg trigger_sha "$TRIGGER_SHA_VAL" \
        '{
            files: $files[0],
            target_languages: $target_languages,
            github_repo: $github_repo,
            github_base_branch: $github_base_branch,
            branch_name: $branch_name,
            commit_message: $commit_message,
            pr_title: $pr_title,
            output_mode: $output_mode
        } + (if $github_head_branch != "" then {github_head_branch: $github_head_branch} else {} end)
          + (if $trigger_sha != "" then {trigger_sha: $trigger_sha} else {} end)' > "$TEMP_DIR/payload.json"
    echo "  Using Autoglot GitHub App for PR creation"
fi

# Make API request using file input (avoids argument length limits)
response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTOGLOT_API_KEY" \
    -d @"$TEMP_DIR/payload.json" \
    "$API_URL/v1/translate" 2>&1)

# Extract HTTP status and body
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# Check for errors
if [ "$http_code" != "202" ] && [ "$http_code" != "200" ]; then
    error_msg=$(echo "$body" | jq -r '.error // "Unknown error"' 2>/dev/null || echo "$body")
    echo -e "${RED}Error ($http_code): $error_msg${NC}"
    exit 1
fi

# Check if this was skipped (our own commit triggered this)
skipped=$(echo "$body" | jq -r '.skipped // false' 2>/dev/null)
if [ "$skipped" = "true" ]; then
    reason=$(echo "$body" | jq -r '.reason // "unknown"' 2>/dev/null)
    echo ""
    echo -e "${YELLOW}Skipped: This commit was made by autoglot${NC}"
    echo "Reason: $reason"
    echo ""
    echo "This prevents infinite translation loops."

    # Set outputs for GitHub Actions
    if [ -n "$GITHUB_OUTPUT" ]; then
        echo "job-id=skipped" >> "$GITHUB_OUTPUT"
        echo "skipped=true" >> "$GITHUB_OUTPUT"
    fi

    echo ""
    echo -e "${GREEN}Done!${NC}"
    exit 0
fi

# Extract job ID
job_id=$(echo "$body" | jq -r '.job_id // "unknown"')

echo ""
echo -e "${GREEN}Translation job submitted!${NC}"
echo ""
echo "Job ID: $job_id"
echo "Status: Queued"

# Set outputs for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "job-id=$job_id" >> "$GITHUB_OUTPUT"
    echo "files-translated=$FILE_COUNT" >> "$GITHUB_OUTPUT"
fi

# Wait for completion if enabled
if [ "$WAIT_FOR_COMPLETION_VAL" = "true" ] && [ "$job_id" != "unknown" ]; then
    echo ""
    echo -e "${BLUE}Waiting for translation to complete...${NC}"

    MAX_WAIT=300  # 5 minutes max
    POLL_INTERVAL=5
    elapsed=0

    while [ $elapsed -lt $MAX_WAIT ]; do
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))

        # Poll job status
        status_response=$(curl -s \
            -H "Authorization: Bearer $AUTOGLOT_API_KEY" \
            "$API_URL/v1/translate/$job_id" 2>&1)

        status=$(echo "$status_response" | jq -r '.status // "unknown"' 2>/dev/null)
        progress=$(echo "$status_response" | jq -r '.progress // 0' 2>/dev/null)

        case "$status" in
            "completed")
                echo -e "${GREEN}✓ Translation completed!${NC}"
                pr_number=$(echo "$status_response" | jq -r '.github_pr_number // empty' 2>/dev/null)
                if [ -n "$pr_number" ]; then
                    echo "PR #$pr_number created"
                    if [ -n "$GITHUB_OUTPUT" ]; then
                        echo "pr-number=$pr_number" >> "$GITHUB_OUTPUT"
                    fi
                fi
                break
                ;;
            "failed")
                error_msg=$(echo "$status_response" | jq -r '.error_message // "Unknown error"' 2>/dev/null)
                echo -e "${RED}✗ Translation failed: $error_msg${NC}"
                exit 1
                ;;
            "cancelled")
                echo -e "${YELLOW}Translation was cancelled${NC}"
                exit 0
                ;;
            *)
                # Still processing - show progress
                printf "\r  Progress: %s%% (${elapsed}s elapsed)" "$progress"
                ;;
        esac
    done

    if [ $elapsed -ge $MAX_WAIT ]; then
        echo ""
        echo -e "${YELLOW}Timed out waiting for completion. Job is still processing.${NC}"
        echo "Track progress: $API_URL/v1/translate/$job_id"
    fi
else
    echo ""
    echo -e "${YELLOW}What happens next:${NC}"
    echo "  1. Autoglot translates your strings (typically completes in seconds/minutes)"
    if [ "$OUTPUT_MODE_VAL" = "commit-to-branch" ]; then
        if [ -n "$HEAD_BRANCH_VAL" ]; then
            echo "  2. Translations are committed to branch '$HEAD_BRANCH_VAL'"
        else
            echo "  2. Translations are committed directly to '$BASE_BRANCH'"
        fi
    else
        echo "  2. A PR is automatically created with the translations"
    fi
    echo "  3. Review and merge when ready"
    echo ""
    echo "Track progress: $API_URL/v1/translate/$job_id"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
