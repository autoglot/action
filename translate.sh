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

echo "Repository: $GITHUB_REPO"
echo "Branch: $BRANCH"
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

# Find all .xcstrings files
if [ -z "$INPUT_FILE" ]; then
    echo "Searching for .xcstrings files..."
    FILES=$(find . -name "*.xcstrings" -type f | grep -v "node_modules" | grep -v ".build" | sort)
else
    # Support glob patterns
    FILES=$(ls $INPUT_FILE 2>/dev/null || echo "")
fi

if [ -z "$FILES" ]; then
    echo -e "${YELLOW}No .xcstrings files found${NC}"
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

    # Use --slurpfile to read file content directly (avoids argument length limits)
    jq --slurpfile content "$file" \
       --arg filename "$clean_filename" \
       '. + [{"filename": $filename, "content": $content[0]}]' \
       "$TEMP_DIR/files.json" > "$TEMP_DIR/files_new.json"
    mv "$TEMP_DIR/files_new.json" "$TEMP_DIR/files.json"
done

echo ""
echo -e "${BLUE}Submitting translation job...${NC}"

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
        '{
            files: $files[0],
            target_languages: $target_languages,
            github_repo: $github_repo,
            github_pat: $github_pat,
            github_base_branch: $github_base_branch,
            branch_name: $branch_name,
            commit_message: $commit_message,
            pr_title: $pr_title
        }' > "$TEMP_DIR/payload.json"
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
        '{
            files: $files[0],
            target_languages: $target_languages,
            github_repo: $github_repo,
            github_base_branch: $github_base_branch,
            branch_name: $branch_name,
            commit_message: $commit_message,
            pr_title: $pr_title
        }' > "$TEMP_DIR/payload.json"
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

# Extract job ID
job_id=$(echo "$body" | jq -r '.job_id // "unknown"')

echo ""
echo -e "${GREEN}Translation job submitted!${NC}"
echo ""
echo "Job ID: $job_id"
echo "Status: Queued"
echo ""
echo -e "${YELLOW}What happens next:${NC}"
echo "  1. Autoglot translates your strings (typically completes in seconds/minutes)"
echo "  2. A PR is automatically created with the translations"
echo "  3. Review and merge when ready"
echo ""
echo "Track progress: $API_URL/v1/translate/$job_id"

# Set outputs for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "job-id=$job_id" >> "$GITHUB_OUTPUT"
    echo "files-translated=$FILE_COUNT" >> "$GITHUB_OUTPUT"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
