# Bank Australia Transaction Export Script

A bash script to export Bank Australia transactions with enhanced payment references and GnuCash-compatible unique transaction IDs.

## Why This Script Exists

Bank Australia's built-in transaction export has two significant issues that make it difficult to use with accounting software like GnuCash:

### 1. Missing Payment References

Bank Australia's OFX export **does not include payment references** for NPP/OSKO payments. The export only shows generic descriptions like "Osko Payment From JOHN SMITH" without the actual payment reference that the sender included (e.g., "Invoice #1234" or "Rent - April").

This makes reconciliation extremely difficult, as you cannot identify what each payment was for without manually cross-referencing with the online banking interface.

### 2. Non-Unique Transaction IDs

Bank Australia's OFX export uses simple sequential transaction IDs (1, 2, 3, etc.) that are **not unique across different exports**. This causes major problems with accounting software like GnuCash:

- GnuCash uses the FITID (Financial Institution Transaction ID) to detect duplicate transactions
- When you import multiple exports, GnuCash sees the same FITID values and assumes they're duplicates
- This results in transactions being skipped during import, even though they're new transactions

This script solves both problems by:
- Fetching payment references directly from Bank Australia's API
- Generating unique FITIDs by appending the transaction date and amount

## What The Script Does

### Overview

1. **Prompts for date range** - Asks for month and year (defaults to last month)
2. **Extracts authentication** - Reads a cURL command from clipboard to get session cookies
3. **Fetches transactions** - Retrieves transaction list via Bank Australia API
4. **Fetches payment references** - For NPP/OSKO payments, fetches detailed payment references (in batches of 10)
5. **Downloads OFX export** - Gets the standard OFX file from Bank Australia
6. **Enhances OFX file** - Modifies the OFX to include payment references and unique transaction IDs
7. **Outputs final file** - Saves enhanced OFX as `bankAustralia-MM-YYYY.ofx`

### OFX File Modifications

The script makes the following minimal modifications to the exported OFX file:

1. **Makes FITIDs unique** - Changes FITID from simple sequential numbers to unique identifiers:
   - Original: `<FITID>1</FITID>`
   - Modified: `<FITID>1.20250930.382</FITID>` (includes date and amount)
   - This is **critical** for GnuCash to accept transactions across multiple imports
2. **Removes "Osko Payment From" prefix** - Cleans up MEMO fields by removing redundant prefixes
3. **Appends payment references** - For NPP/OSKO transactions, appends the payment reference to the MEMO field:
   - Original: `<MEMO>Osko Payment From JOHN SMITH</MEMO>`
   - Modified: `<MEMO>JOHN SMITH - Invoice 1234</MEMO>`

## How To Use

### Prerequisites

- Bash shell (macOS or Linux)
- `curl` command
- `jq` command (recommended, but script has fallbacks)
- Clipboard utility: `pbpaste`/`pbcopy` (macOS), `xclip`, or `xsel` (Linux)

### Step-by-Step Instructions

1. **Make the script executable**:
   ```bash
   chmod +x export.sh
   ```

2. **Run the script**:
   ```bash
   ./export.sh
   ```

3. **Enter the month and year** when prompted (or press Enter for defaults)

4. **Get the cURL command**:
   - Log into [Bank Australia](https://digital.bankaust.com.au)
   - **Click the chevron/arrow** next to your account name to expand the transactions view
   - Open your browser's **Developer Tools** (F12 or Cmd+Option+I on Mac)
   - Go to the **Network** tab
   - Look for a request to `platform.axd?u=transaction%2FGetTransactionHistory` or similar
   - **Right-click** on the request → **Copy** → **Copy as cURL**
   - The cURL command is now in your clipboard

5. **Press Enter** in the terminal - The script will automatically read the cURL from your clipboard

6. **Wait for processing** - The script will:
   - Fetch all transactions
   - Download payment references for NPP/OSKO payments
   - Generate the enhanced OFX file

7. **Import to GnuCash** - Import the generated `bankAustralia-MM-YYYY.ofx` file into your accounting software

### Output Files

- **`bankAustralia-MM-YYYY.ofx`** - The enhanced OFX file ready for import
- **`bankAustralia-MM-YYYY-original.ofx`** - Original unmodified OFX (only in debug mode)

## Debug Mode

Run the script with `--debug` flag to see detailed information:

```bash
./export.sh --debug
```

Debug mode shows:
- Date range calculation details
- Full authentication parameters (Cookie, CSRF Token, Account Number)
- Individual NPP payment fetches as they happen
- Batch processing progress
- Transaction ID to description mapping table
- List of NPP transactions missing descriptions
- Temporary file paths
- OFX export parameters
- Original OFX file is saved for comparison

This is useful for:
- Troubleshooting authentication issues
- Verifying payment references were fetched correctly
- Debugging missing transactions
- Understanding what the script is doing at each step

## Troubleshooting

### "No transactions found for the specified date range"

- Check that you selected the correct month/year
- Verify you have transactions in that period
- Try re-copying the cURL command (session may have expired)

### "Could not extract Cookie from curl command"

- Make sure you copied the entire cURL command
- Ensure you're copying from the correct network request
- The request should be to `platform.axd?u=transaction%2FGetTransactionHistory`

### Transactions missing from import

- Run with `--debug` to see which transactions are being processed
- Check that the date range matches your expectations
- Verify the OFX file has the expected number of `<STMTTRN>` blocks

### Authentication errors

- Your session cookies may have expired
- Log out and log back into Bank Australia
- Copy a fresh cURL command
- Try running the script again immediately

## License

This script is provided as-is for personal use. Use at your own risk.

## Contributing

Feel free to submit issues or pull requests if you find bugs or have improvements.
