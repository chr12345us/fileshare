#!/usr/bin/env python3
"""Upload files to the Radware Fileshare (JumboMail "filepile") portal.

The portal is a JavaScript app with no public API, so this drives a real
browser via Playwright:

    step 1: email + "No Case / New Service Request" (or an SR number) -> Next
    step 2: attach files -> Send
    step 3: wait for the upload to finish

Usage:
    python upload_to_radware.py --email you@example.com file1.pcap file2.zip
    python upload_to_radware.py --email you@example.com --sr 12345678 dump.tar.gz
    python upload_to_radware.py --email you@example.com --show file.zip

First time setup:
    pip install -r requirements.txt
    playwright install chromium
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeout
from playwright.sync_api import sync_playwright

PAGE_URL = "https://fileshare.radware.com/en/page/radware-filepile"
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Text shown by the portal once the transfer has completed.
DONE_PATTERNS = ("sent successfully", "files were sent", "upload complete", "thank you")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload files to Radware Fileshare.")
    parser.add_argument("files", nargs="+", type=Path, help="File(s) to upload.")
    parser.add_argument("--email", required=True, help="Your email address (required by the form).")
    parser.add_argument(
        "--sr",
        metavar="NUMBER",
        help="Existing Service Request number. Omitted means 'No Case / New Service Request'.",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Run with a visible browser window instead of headless.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=3600,
        help="Seconds to wait for the upload to finish (default: 3600).",
    )
    return parser.parse_args(argv)


def validate(args: argparse.Namespace) -> list[Path]:
    if not EMAIL_RE.match(args.email):
        sys.exit(f"error: '{args.email}' does not look like an email address")

    resolved: list[Path] = []
    for raw in args.files:
        path = raw.expanduser().resolve()
        if not path.is_file():
            sys.exit(f"error: not a file: {path}")
        resolved.append(path)
    return resolved


def upload(files: list[Path], email: str, sr: str | None, headless: bool, timeout_s: int) -> None:
    total = sum(f.stat().st_size for f in files)
    print(f"Uploading {len(files)} file(s), {total / 1024 / 1024:.1f} MiB, as {email}")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        page = browser.new_context(accept_downloads=False).new_page()
        page.set_default_timeout(60_000)

        try:
            page.goto(PAGE_URL, wait_until="domcontentloaded")

            # Cookie banner covers the form on a fresh profile.
            consent = page.locator("#simple-consent-btn")
            try:
                consent.click(timeout=5_000)
            except PlaywrightError:
                pass

            # --- step 1: details form ---
            page.fill("input[type=email][name=email]", email)

            choice = "Existing Service Request" if sr else "No Case / New Service Request"
            page.get_by_text(choice, exact=True).click()
            if sr:
                page.fill("input[type=text][name=text]", sr)

            page.get_by_role("button", name="Next").click()

            # --- step 2: attach and send ---
            file_input = page.locator("input.files-input").first
            file_input.wait_for(state="attached")
            file_input.set_input_files([str(f) for f in files])

            send = page.get_by_role("button", name="Send")
            send.wait_for(state="visible")
            send.click()
            print("Sent. Waiting for the transfer to finish...")

            # --- step 3: wait for completion ---
            done = re.compile("|".join(DONE_PATTERNS), re.IGNORECASE)
            page.wait_for_function(
                "p => new RegExp(p, 'i').test(document.body.innerText)",
                arg=done.pattern,
                timeout=timeout_s * 1000,
            )
        except PlaywrightTimeout:
            body = page.inner_text("body")[:2000] if not page.is_closed() else ""
            browser.close()
            sys.exit(f"error: timed out waiting for the upload to complete.\nPage said:\n{body}")
        except PlaywrightError as exc:
            browser.close()
            sys.exit(f"error: browser automation failed: {exc}")

        print("Upload complete.")
        for line in page.inner_text("body").splitlines():
            line = line.strip()
            if line and done.search(line):
                print(f"  {line}")
        browser.close()


def main() -> None:
    args = parse_args()
    upload(validate(args), args.email, args.sr, not args.show, args.timeout)


if __name__ == "__main__":
    main()
