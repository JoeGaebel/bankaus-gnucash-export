#!/bin/bash

# Bank Australia Transaction Export Script
# Step 1: Get month and calculate date range

# Get current year
CURRENT_YEAR=$(date +%Y)

# Prompt for month (1-12)
echo "Enter month (1-12):"
read -r MONTH

# Validate month input
if ! [[ "$MONTH" =~ ^[0-9]+$ ]] || [ "$MONTH" -lt 1 ] || [ "$MONTH" -gt 12 ]; then
    echo "Error: Month must be a number between 1 and 12"
    exit 1
fi

# Prompt for year with default
echo "Enter year (default: $CURRENT_YEAR):"
read -r YEAR
YEAR=${YEAR:-$CURRENT_YEAR}

# Validate year input
if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
    echo "Error: Year must be a 4-digit number"
    exit 1
fi

# Pad month with leading zero if needed
MONTH_PADDED=$(printf "%02d" "$MONTH")

# Calculate first day of month
BEGIN_DATE="${YEAR}-${MONTH_PADDED}-01T00:00:00.000"

# Calculate last day of month
# Use date command to get the last day (different syntax for macOS/BSD vs Linux)
if date -v 1d > /dev/null 2>&1; then
    # macOS/BSD date
    LAST_DAY=$(date -j -v1d -v+1m -v-1d -f "%Y-%m-%d" "${YEAR}-${MONTH_PADDED}-01" "+%d" 2>/dev/null)
else
    # GNU date (Linux)
    LAST_DAY=$(date -d "${YEAR}-${MONTH_PADDED}-01 +1 month -1 day" "+%d" 2>/dev/null)
fi

# Fallback: calculate last day using simple logic
if [ -z "$LAST_DAY" ]; then
    case $MONTH in
        2)
            # Check for leap year
            if (( YEAR % 4 == 0 && (YEAR % 100 != 0 || YEAR % 400 == 0) )); then
                LAST_DAY=29
            else
                LAST_DAY=28
            fi
            ;;
        4|6|9|11)
            LAST_DAY=30
            ;;
        *)
            LAST_DAY=31
            ;;
    esac
fi

END_DATE="${YEAR}-${MONTH_PADDED}-${LAST_DAY}T00:00:00.000"

echo ""
echo "Date range calculated:"
echo "  Begin Date: $BEGIN_DATE"
echo "  End Date:   $END_DATE"
echo ""

# Step 2: Get curl command and extract authentication parameters
echo "Save your curl command to a file called 'curl.txt' in the current directory."
echo "Press Enter when ready to continue..."
read -r

if [ ! -f "curl.txt" ]; then
    echo "Error: curl.txt not found in current directory"
    exit 1
fi

CURL_INPUT=$(cat curl.txt)

# Extract Cookie header
COOKIE=$(echo "$CURL_INPUT" | grep -o "Cookie: [^'\"]*" | sed 's/Cookie: //')

# Extract __RequestVerificationToken from Cookie header (if present)
CSRF_TOKEN_COOKIE=$(echo "$COOKIE" | grep -o '__RequestVerificationToken=[^;]*' | sed 's/__RequestVerificationToken=//')

# Extract __RequestVerificationToken from request body (if present in --data-raw)
CSRF_TOKEN_BODY=$(echo "$CURL_INPUT" | grep -o '"__RequestVerificationToken":"[^"]*"' | sed 's/"__RequestVerificationToken":"//' | sed 's/"$//')

# Use body token if available, otherwise use cookie token
if [ -n "$CSRF_TOKEN_BODY" ]; then
    CSRF_TOKEN="$CSRF_TOKEN_BODY"
else
    CSRF_TOKEN="$CSRF_TOKEN_COOKIE"
fi

# Extract Account Number from the request body
ACCOUNT_NUMBER=$(echo "$CURL_INPUT" | grep -o '"AccountNumber":"[^"]*"' | sed 's/"AccountNumber":"//' | sed 's/"$//')

# Validation
if [ -z "$COOKIE" ]; then
    echo "Error: Could not extract Cookie from curl command"
    exit 1
fi

if [ -z "$CSRF_TOKEN" ]; then
    echo "Warning: Could not extract __RequestVerificationToken"
fi

if [ -z "$ACCOUNT_NUMBER" ]; then
    echo "Warning: Could not extract AccountNumber from curl command"
fi

echo ""
echo "Authentication parameters extracted successfully:"
echo "  Cookie: ${COOKIE:0:100}..." # Show first 100 chars
echo "  CSRF Token: $CSRF_TOKEN"
echo "  Account Number: $ACCOUNT_NUMBER"
echo ""

# Step 3: Fetch transactions for the specified month
echo "Fetching transactions for ${YEAR}-${MONTH_PADDED}..."

TRANSACTIONS_FILE=$(mktemp)
TRANSACTION_RESPONSE=$(curl -s 'https://digital.bankaust.com.au/platform.axd?u=transaction%2FGetTransactionHistory' \
  --compressed \
  -X POST \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0' \
  -H 'Accept: application/json; charset=utf-8' \
  -H 'Accept-Language: en-US,en;q=0.5' \
  -H 'Accept-Encoding: gzip, deflate, br, zstd' \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H 'X-Requested-With: XMLHttpRequest' \
  -H 'Origin: https://digital.bankaust.com.au' \
  -H 'Connection: keep-alive' \
  -H "Cookie: $COOKIE" \
  -H 'Sec-Fetch-Dest: empty' \
  -H 'Sec-Fetch-Mode: cors' \
  -H 'Sec-Fetch-Site: same-origin' \
  --data-raw "{\"__RequestVerificationToken\":\"$CSRF_TOKEN\",\"rdoTransctionType\":\"46\",\"Description\":\"\",\"TransactionTypeId\":\"40\",\"TransactionPeriod\":\"Selected date range\",\"BeginDate\":\"$BEGIN_DATE\",\"EndDate\":\"$END_DATE\",\"MinimumOrExactAmount\":\"\",\"MaximumAmount\":\"\",\"MinimumOrExactChequeNumber\":\"\",\"TransactionOrder\":\"0\",\"DateFormat\":\"dd/MM/yyyy\",\"\":\"\" ,\"NewestTransactionFirst\":true,\"TransactionTypeDesc\":\"ALL\",\"AccountNumber\":\"$ACCOUNT_NUMBER\",\"ExcludeManualTransactions\":false,\"MinimumAmount\":\"\",\"isSearchFiltered\":false}")

echo "$TRANSACTION_RESPONSE" > "$TRANSACTIONS_FILE"

# Count transactions using jq or basic grep fallback
if command -v jq &> /dev/null; then
    TRANSACTION_COUNT=$(echo "$TRANSACTION_RESPONSE" | jq '.TransactionDetails | length')
else
    TRANSACTION_COUNT=$(echo "$TRANSACTION_RESPONSE" | grep -o '"TransactionId":' | wc -l | tr -d ' ')
fi

echo "Found $TRANSACTION_COUNT transactions"
echo ""

# Step 4: Extract descriptions for all transactions and fetch NPP payment details
echo "Processing transaction descriptions..."

DESCRIPTIONS_FILE=$(mktemp)
TEMP_DIR=$(mktemp -d)

# First, save LongDescription for all transactions
if command -v jq &> /dev/null; then
    echo "$TRANSACTION_RESPONSE" | jq -r '.TransactionDetails[] | "\(.TransactionId)|\(.LongDescription // "")"' > "$DESCRIPTIONS_FILE"
else
    # Fallback parsing (simplified)
    echo "Warning: jq not found, using basic parsing. Install jq for better reliability."
fi

# Extract NPP Payment IDs and Transaction IDs for detailed lookups
if command -v jq &> /dev/null; then
    # Use jq for cleaner parsing
    NPP_TRANSACTIONS=$(echo "$TRANSACTION_RESPONSE" | jq -r '.TransactionDetails[] | select(.NppPaymentId != null) | "\(.TransactionId)|\(.NppPaymentId)"')
else
    # Fallback: extract manually (more fragile)
    NPP_TRANSACTIONS=$(echo "$TRANSACTION_RESPONSE" | grep -o '"TransactionId":[^,]*,"TransactionCategoryId".*"NppPaymentId":"[^"]*"' | sed -E 's/"TransactionId":([^,]*),.*"NppPaymentId":"([^"]*)"/\1|\2/')
fi

NPP_COUNT=$(echo "$NPP_TRANSACTIONS" | grep -c '^' || echo "0")
echo "Found $NPP_COUNT NPP/OSKO transactions to fetch payment references for"

# Function to fetch NPP payment details and save to temp file
fetch_payment_details() {
    local txn_id=$1
    local payment_id=$2
    local cookie=$3
    local csrf=$4
    local temp_dir=$5

    DETAILS=$(curl -s 'https://digital.bankaust.com.au/platform.axd?u=npp%2FGetPayment' \
      --compressed \
      -X POST \
      -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0' \
      -H 'Accept: application/json; charset=utf-8' \
      -H 'Accept-Language: en-US,en;q=0.5' \
      -H 'Accept-Encoding: gzip, deflate, br, zstd' \
      -H 'Content-Type: application/json; charset=utf-8' \
      -H 'X-Requested-With: XMLHttpRequest' \
      -H 'Origin: https://digital.bankaust.com.au' \
      -H 'Connection: keep-alive' \
      -H "Cookie: $cookie" \
      -H 'Sec-Fetch-Dest: empty' \
      -H 'Sec-Fetch-Mode: cors' \
      -H 'Sec-Fetch-Site: same-origin' \
      --data-raw "{\"PaymentId\":\"$payment_id\"}")

    # Extract description from response
    if command -v jq &> /dev/null; then
        DESCRIPTION=$(echo "$DETAILS" | jq -r '.Description // ""')
    else
        DESCRIPTION=$(echo "$DETAILS" | grep -o '"Description":"[^"]*"' | head -1 | sed 's/"Description":"//' | sed 's/"$//')
    fi

    # Save using the transaction list ID (not the bank's internal transaction ID)
    # Clean the txn_id to remove any decimal points for filename safety
    # Also remove any other problematic characters
    clean_txn_id=$(echo "$txn_id" | sed 's/[^0-9]//g')

    # Debug: Save full response for troubleshooting
    echo "$DETAILS" > "${temp_dir}/${clean_txn_id}_full.json"
    echo "${txn_id}|${DESCRIPTION}" > "${temp_dir}/${clean_txn_id}.txt"

    # Also log to stderr for debugging (visible in terminal)
    echo "  Fetched: TxnID=$txn_id -> Description='$DESCRIPTION'" >&2
}

export -f fetch_payment_details

# Process NPP transactions in batches of 10
if [ $NPP_COUNT -gt 0 ]; then
    BATCH_SIZE=10
    BATCH_COUNT=0

    # Convert to array to avoid subshell issues with pipe
    while IFS='|' read -r txn_id payment_id; do
        if [ -n "$txn_id" ] && [ -n "$payment_id" ]; then
            fetch_payment_details "$txn_id" "$payment_id" "$COOKIE" "$CSRF_TOKEN" "$TEMP_DIR" &

            BATCH_COUNT=$((BATCH_COUNT + 1))

            # Wait every 10 requests
            if [ $((BATCH_COUNT % BATCH_SIZE)) -eq 0 ]; then
                wait
                echo "  Processed $BATCH_COUNT NPP transactions..."
            fi
        fi
    done <<< "$NPP_TRANSACTIONS"

    # Wait for any remaining background jobs
    wait
    echo "Completed fetching NPP payment details (total: $BATCH_COUNT)"
fi

# Create final descriptions file with NPP details replacing long descriptions
FINAL_DESCRIPTIONS_FILE=$(mktemp)

if command -v jq &> /dev/null; then
    # For each transaction, use NPP description if available, otherwise skip
    while IFS='|' read -r txn_id long_desc; do
        # Clean transaction ID for file lookup (must match cleaning in fetch function)
        clean_txn_id=$(echo "$txn_id" | sed 's/[^0-9]//g')
        npp_detail_file="${TEMP_DIR}/${clean_txn_id}.txt"

        if [ -f "$npp_detail_file" ]; then
            # Use ONLY the NPP description (the payment reference)
            npp_desc=$(cat "$npp_detail_file" | cut -d'|' -f2)
            if [ -n "$npp_desc" ]; then
                # Only include transactions with non-empty descriptions
                echo "${txn_id}|${npp_desc}" >> "$FINAL_DESCRIPTIONS_FILE"
            fi
        fi
        # Skip transactions without NPP payment details or empty descriptions
    done < "$DESCRIPTIONS_FILE"
else
    # If no jq, just use the basic descriptions
    cp "$DESCRIPTIONS_FILE" "$FINAL_DESCRIPTIONS_FILE"
fi

echo ""
echo "Transaction ID to Description mapping:"
cat "$FINAL_DESCRIPTIONS_FILE"
echo ""

# Count how many descriptions we successfully extracted
DESCRIPTION_COUNT=$(wc -l < "$FINAL_DESCRIPTIONS_FILE" | tr -d ' ')
echo "Successfully extracted $DESCRIPTION_COUNT payment descriptions out of $NPP_COUNT NPP/OSKO transactions"

# Show which NPP transactions are missing descriptions
if [ "$DESCRIPTION_COUNT" -lt "$NPP_COUNT" ]; then
    echo ""
    echo "NPP transactions missing descriptions:"
    if command -v jq &> /dev/null; then
        echo "$NPP_TRANSACTIONS" | while IFS='|' read -r txn_id payment_id; do
            if [ -n "$txn_id" ]; then
                clean_txn_id=$(echo "$txn_id" | tr -d '.')
                if [ ! -f "${TEMP_DIR}/${clean_txn_id}.txt" ]; then
                    echo "  Transaction ID $txn_id (PaymentId: $payment_id) - no response saved"
                elif [ ! -s "${TEMP_DIR}/${clean_txn_id}.txt" ] || [ "$(cat "${TEMP_DIR}/${clean_txn_id}.txt" | cut -d'|' -f2)" = "" ]; then
                    echo "  Transaction ID $txn_id (PaymentId: $payment_id) - empty description"
                    if [ -f "${TEMP_DIR}/${clean_txn_id}_full.json" ]; then
                        echo "    Full response: $(cat "${TEMP_DIR}/${clean_txn_id}_full.json") "
                    fi
                fi
            fi
        done
    fi
fi
echo ""

# Store file paths for later use
echo "Temp files created:"
echo "  Transactions: $TRANSACTIONS_FILE"
echo "  Descriptions: $FINAL_DESCRIPTIONS_FILE"
echo "  Temp dir: $TEMP_DIR"
echo ""

# Step 5: Fetch the OFX export
echo "Fetching OFX export..."

# URL encode the dates (replace : with %3A)
BEGIN_DATE_ENCODED=$(echo "$BEGIN_DATE" | sed 's/:/%3A/g')
END_DATE_ENCODED=$(echo "$END_DATE" | sed 's/:/%3A/g')

echo "Debug - Export parameters:"
echo "  BeginDate: $BEGIN_DATE_ENCODED"
echo "  EndDate: $END_DATE_ENCODED"
echo "  Account: $ACCOUNT_NUMBER"
echo "  CSRF Token (first 20 chars): ${CSRF_TOKEN:0:20}..."

OFX_RESPONSE=$(curl -s 'https://digital.bankaust.com.au/platform.axd?u=transaction/ExportToOfx' \
  -X POST \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0' \
  -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
  -H 'Accept-Language: en-US,en;q=0.5' \
  -H 'Accept-Encoding: gzip, deflate, br, zstd' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Origin: null' \
  -H 'Connection: keep-alive' \
  -H "Cookie: $COOKIE" \
  -H 'Sec-Fetch-Dest: document' \
  -H 'Sec-Fetch-Mode: navigate' \
  -H 'Sec-Fetch-Site: same-origin' \
  -H 'Sec-Fetch-User: ?1' \
  --data-raw "__RequestVerificationToken=${CSRF_TOKEN}&rdoTransctionType=46&TransactionTypeId=40&TransactionPeriod=Selected+date+range&BeginDate=${BEGIN_DATE_ENCODED}&EndDate=${END_DATE_ENCODED}&TransactionOrder=0&DateFormat=dd%2FMM%2Fyyyy&NewestTransactionFirst=true&TransactionTypeDesc=ALL&AccountNumber=${ACCOUNT_NUMBER}")

# Save OFX response to file
OFX_FILE=$(mktemp)

if [ -z "$OFX_RESPONSE" ]; then
    echo "Error: Empty response from export endpoint"
    exit 1
fi

# Check if response is base64 or plain text OFX
if echo "$OFX_RESPONSE" | head -c 20 | grep -q "OFXHEADER"; then
    # Response is already plain text OFX
    echo "$OFX_RESPONSE" > "$OFX_FILE"
    echo "OFX export downloaded (plain text)"
else
    # Response is base64 encoded
    echo "$OFX_RESPONSE" | base64 -d > "$OFX_FILE"
    echo "OFX export downloaded and decoded from base64"
fi

echo "OFX file size: $(wc -c < "$OFX_FILE") bytes"

# Count transactions in the OFX file
OFX_TRANSACTION_COUNT=$(grep -c "<STMTTRN>" "$OFX_FILE" || echo "0")
echo "Transactions in OFX file: $OFX_TRANSACTION_COUNT"
echo ""

# If transaction count doesn't match, show warning
if [ "$OFX_TRANSACTION_COUNT" != "$TRANSACTION_COUNT" ]; then
    echo "⚠ Warning: OFX has $OFX_TRANSACTION_COUNT transactions but we fetched $TRANSACTION_COUNT from the API"
    echo "  This might indicate the export endpoint is filtering differently"
    echo ""
fi

# Step 6: Update MEMO tags with descriptions
echo "Updating MEMO tags with payment descriptions..."

UPDATED_OFX_FILE=$(mktemp)

# Read the OFX file and update MEMO tags
awk -v descriptions_file="$FINAL_DESCRIPTIONS_FILE" '
BEGIN {
    # Load descriptions into an associative array
    while ((getline line < descriptions_file) > 0) {
        split(line, parts, "|")
        # Remove .0 from transaction ID to match FITID
        gsub(/\.0$/, "", parts[1])
        descriptions[parts[1]] = parts[2]
    }
    close(descriptions_file)

    current_fitid = ""
    updated_count = 0
}

# Fix DTEND format to be consistent (YYYYMMDD000000 instead of YYYYMMDD235959)
/<DTEND>/ {
    dtend_line = $0
    # Change format from YYYYMMDD235959 to YYYYMMDD000000
    gsub(/235959/, "000000", dtend_line)
    print dtend_line
    next
}

# Track DTPOSTED to add DTUSER tag and store for FITID
/<DTPOSTED>/ {
    print
    # Extract date and store for FITID uniqueness
    dtposted_value = $0
    gsub(/.*<DTPOSTED>/, "", dtposted_value)
    gsub(/<\/DTPOSTED>.*/, "", dtposted_value)
    print "<DTUSER>" dtposted_value
    next
}

# Track TRNAMT for FITID uniqueness
/<TRNAMT>/ {
    # Extract amount and store for FITID
    trnamt_value = $0
    gsub(/.*<TRNAMT>/, "", trnamt_value)
    gsub(/<\/TRNAMT>.*/, "", trnamt_value)
    # Remove negative sign and decimal for cleaner FITID
    gsub(/-/, "", trnamt_value)
    gsub(/\./, "", trnamt_value)
    print
    next
}

# Track FITID and make it unique
/<FITID>/ {
    # Extract FITID value
    fitid_line = $0
    gsub(/.*<FITID>/, "", fitid_line)
    gsub(/<\/FITID>.*/, "", fitid_line)
    gsub(/[^0-9]/, "", fitid_line)
    current_fitid = fitid_line

    # Make FITID unique by appending date and amount
    unique_fitid = fitid_line "." dtposted_value "." trnamt_value
    print "<FITID>" unique_fitid
    next
}

# Update MEMO tag if we have a description for this FITID
/<MEMO>/ {
    if (current_fitid != "" && current_fitid in descriptions && descriptions[current_fitid] != "") {
        # Extract current memo text
        memo_line = $0
        gsub(/.*<MEMO>/, "", memo_line)
        gsub(/<\/MEMO>.*/, "", memo_line)
        # Trim trailing whitespace from memo
        gsub(/[ \t]+$/, "", memo_line)
        # Trim trailing whitespace from description
        desc = descriptions[current_fitid]
        gsub(/[ \t]+$/, "", desc)
        # Append description to memo
        new_memo = memo_line " - " desc
        print "<MEMO>" new_memo
        updated_count++
        current_fitid = ""
        next
    }
    # If no description, print line as-is and reset FITID
    print
    current_fitid = ""
    next
}

# Print all other lines as-is
{
    print
}

END {
    # Output count to a temp file so we can read it in bash
    print updated_count > "/tmp/ofx_update_count.txt"
}
' "$OFX_FILE" > "$UPDATED_OFX_FILE"

# Get the accurate count from awk
UPDATED_COUNT=$(cat /tmp/ofx_update_count.txt 2>/dev/null || echo "0")
echo "Updated $UPDATED_COUNT MEMO tags with payment descriptions"
echo ""

# Step 7: Save the final OFX files
ORIGINAL_FILENAME="bank_export_${YEAR}_${MONTH_PADDED}_original.ofx"
UPDATED_FILENAME="bank_export_${YEAR}_${MONTH_PADDED}.ofx"

cp "$OFX_FILE" "$ORIGINAL_FILENAME"
cp "$UPDATED_OFX_FILE" "$UPDATED_FILENAME"

echo "✓ Export complete!"
echo ""
echo "Output files:"
echo "  - Original: $ORIGINAL_FILENAME"
echo "  - Updated:  $UPDATED_FILENAME"
echo ""
echo "Summary:"
echo "  - Total transactions: $TRANSACTION_COUNT"
echo "  - NPP/OSKO transactions: $NPP_COUNT"
echo "  - Descriptions fetched: $DESCRIPTION_COUNT"
echo "  - MEMO tags updated: $UPDATED_COUNT"
echo ""
echo "To compare the files, run:"
echo "  diff $ORIGINAL_FILENAME $UPDATED_FILENAME"
echo ""
