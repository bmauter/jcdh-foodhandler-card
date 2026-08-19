#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 \"Name\" \"email@example.com\""
    exit 1
fi

NAME="$1"
EMAIL="$2"

BASE_URL='https://www.jcdh.org'
REGISTER_PATH='/SitePages/Programs-Services/EnvironmentalHealth/FoodProtection/VolFoodHandlerReg.aspx?RequestType=Individual'
REGISTER_URL="$BASE_URL$REGISTER_PATH"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

REGISTER_HTML="$WORKDIR/register.html"
POST_BODY="$WORKDIR/post-body.html"
HEADERS="$WORKDIR/headers.txt"
TRAINING_HTML="$WORKDIR/training.html"
PLAYWRIGHT_SCRIPT="$WORKDIR/render-pdf.mjs"

#
# Check prerequisites.
#
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js is not installed." >&2
    echo "Install it with:" >&2
    echo "  brew install node" >&2
    exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
    echo "ERROR: npx is not available." >&2
    exit 1
fi

echo "Fetching registration page..."

curl -fsS \
    "$REGISTER_URL" \
    -o "$REGISTER_HTML"

#
# Extract fresh ASP.NET hidden fields.
#
read -r VIEWSTATE EVENTVALIDATION VIEWSTATEGENERATOR < <(
    python3 - "$REGISTER_HTML" <<'PY'
import sys
from html.parser import HTMLParser

filename = sys.argv[1]

wanted = {
    "__VIEWSTATE": "",
    "__EVENTVALIDATION": "",
    "__VIEWSTATEGENERATOR": "",
}

class Parser(HTMLParser):
    def handle_starttag(self, tag, attrs):
        if tag.lower() != "input":
            return

        attrs = dict(attrs)
        name = attrs.get("name")

        if name in wanted:
            wanted[name] = attrs.get("value", "")

parser = Parser()

with open(filename, encoding="utf-8", errors="replace") as f:
    parser.feed(f.read())

if not wanted["__VIEWSTATE"]:
    raise SystemExit("ERROR: __VIEWSTATE not found")

if not wanted["__EVENTVALIDATION"]:
    raise SystemExit("ERROR: __EVENTVALIDATION not found")

print(
    wanted["__VIEWSTATE"],
    wanted["__EVENTVALIDATION"],
    wanted["__VIEWSTATEGENERATOR"],
)
PY
)

echo "Submitting registration for $NAME <$EMAIL>..."

HTTP_STATUS="$(
    curl -sS \
        -X POST \
        -D "$HEADERS" \
        -o "$POST_BODY" \
        -w '%{http_code}' \
        --data-urlencode "__EVENTTARGET=" \
        --data-urlencode "__EVENTARGUMENT=" \
        --data-urlencode "__VIEWSTATE=$VIEWSTATE" \
        --data-urlencode "__VIEWSTATEGENERATOR=$VIEWSTATEGENERATOR" \
        --data-urlencode "__EVENTVALIDATION=$EVENTVALIDATION" \
        --data-urlencode 'ctl00$TextBox1Mobile=' \
        --data-urlencode 'ctl00$siteSearchText=' \
        --data-urlencode "ctl00\$MainContent\$txtVFHName=$NAME" \
        --data-urlencode "ctl00\$MainContent\$txtVFHEmail=$EMAIL" \
        --data-urlencode 'ctl00$MainContent$btnContinue=Continue' \
        "$REGISTER_URL"
)"

if [ "$HTTP_STATUS" != "302" ]; then
    echo "ERROR: expected HTTP 302, got $HTTP_STATUS" >&2
    echo >&2
    cat "$POST_BODY" >&2
    exit 1
fi

#
# Read the Location header.
#
LOCATION="$(
    grep -i '^location:' "$HEADERS" |
    tail -1 |
    sed 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//' |
    tr -d '\r'
)"

if [ -z "$LOCATION" ]; then
    echo "ERROR: 302 response did not contain a Location header." >&2
    echo >&2
    cat "$HEADERS" >&2
    exit 1
fi

if [[ "$LOCATION" == /* ]]; then
    LOCATION_URL="$BASE_URL$LOCATION"
else
    LOCATION_URL="$LOCATION"
fi

echo "Redirect URL: $LOCATION_URL"

#
# Visit the training page, since that's where JCDH sent us.
#
echo "Fetching training page..."

curl -fsS \
    "$LOCATION_URL" \
    -o "$TRAINING_HTML"

#
# Build the print URL while preserving SessionId.
#
CARD_URL="${LOCATION_URL/VolFoodHandlerTraining.aspx/VolFoodHandlerCardPrint.aspx}"

echo "Card URL: $CARD_URL"

#
# Make a safe output filename.
#
PDF_NAME="$(
    python3 - "$NAME" <<'PY'
import sys

name = sys.argv[1].strip()

for c in '/:\\':
    name = name.replace(c, '-')

print(name + '.pdf')
PY
)"

PDF_PATH="$(pwd)/$PDF_NAME"

#
# Create a tiny Playwright program.
#
cat > "$PLAYWRIGHT_SCRIPT" <<'JS'
import { chromium } from 'playwright';

const cardUrl = process.argv[2];
const pdfPath = process.argv[3];

const browser = await chromium.launch({
    headless: true
});

try {
    const page = await browser.newPage({
        viewport: {
            width: 1280,
            height: 900
        }
    });

    console.log(`Loading ${cardUrl}`);

    await page.goto(cardUrl, {
        waitUntil: 'networkidle'
    });

    //
    // Render using the page's normal screen CSS rather than switching
    // everything to @media print.
    //
    await page.emulateMedia({
        media: 'screen'
    });

    //
    // Wait for fonts and images before printing.
    //
    await page.evaluate(async () => {
        if (document.fonts?.ready) {
            await document.fonts.ready;
        }

        const images = Array.from(document.images);

        await Promise.all(
            images.map(img => {
                if (img.complete) {
                    return Promise.resolve();
                }

                return new Promise(resolve => {
                    img.addEventListener('load', resolve, { once: true });
                    img.addEventListener('error', resolve, { once: true });
                });
            })
        );
    });

    await page.pdf({
        path: pdfPath,
        format: 'Letter',
        printBackground: true,
        preferCSSPageSize: true,
        margin: {
            top: '0.25in',
            right: '0.25in',
            bottom: '0.25in',
            left: '0.25in'
        }
    });

    console.log(`Saved: ${pdfPath}`);
}
finally {
    await browser.close();
}
JS

echo
echo "Checking Playwright..."

#
# Use a temporary npm project so we don't clutter the current directory.
#
pushd "$WORKDIR" >/dev/null

npm init -y >/dev/null 2>&1

npm install --silent playwright

#
# Install Playwright's own Chromium binary.
# This does NOT install Google Chrome.
#
npx playwright install chromium

echo
echo "Generating PDF..."

node \
    "$PLAYWRIGHT_SCRIPT" \
    "$CARD_URL" \
    "$PDF_PATH"

popd >/dev/null

echo
echo "Saved: $PDF_PATH"