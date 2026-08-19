# JCDH Volunteer Food Handler Card

A small command-line script that automates generating a Jefferson County Department of Health Volunteer Food Handler Card.

Why would I write this?  The Jefferson County Department of Health website is really difficult to use.  The video we have to watch only works on MS Windows.  We need it to be able to view on our iPhones and Android devices easily.  Then we need an easy way to signal that we watched the video.  Their website makes this very difficult too.  This script does that second part.

## Requirements

- macOS or Linux
- `curl`
- Python 3
- Node.js / npm
- Playwright with Chromium

Install Node.js on macOS with Homebrew:

```bash
brew install node
```

Install Playwright:

```bash
npm install playwright
```

## Usage

Make the script executable:

```bash
chmod +x get-jcdh-card.sh
```

Run it with the volunteer's name and email address:

```bash
./get-jcdh-card.sh "Bobby Boucher" "bobby@mailinator.com"
```

The resulting PDF is written to the current directory using the volunteer's name:

```text
Bobby Boucher.pdf
```

## How It Works

The script automates the JCDH individual Volunteer Food Handler registration process:

1. Downloads the JCDH registration page.
2. Extracts the ASP.NET `__VIEWSTATE`, `__EVENTVALIDATION`, and `__VIEWSTATEGENERATOR` values.
3. Submits those values along with the supplied name and email address.
4. Captures the HTTP 302 redirect returned by JCDH.
5. Uses the redirect URL to locate the volunteer's generated card.
6. Opens the card page using Playwright's headless Chromium browser.
7. Waits for images, fonts, and other page resources to load.
8. Prints the rendered page to a PDF.

Using a real browser engine for the final step preserves the JCDH page's CSS and images more accurately than HTML-to-PDF converters such as WeasyPrint.

## Example

```bash
./get-jcdh-card.sh "Jane Smith" "jane@example.com"
```

creates:

```text
Jane Smith.pdf
```

The script does not store the supplied name or email address locally beyond the temporary files needed while it runs.
