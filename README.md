# Radware Fileshare Uploader / Downloader

**Version:** 1.4

Command-line tools for the Radware file sharing portal at
<https://fileshare.radware.com/en/page/radware-filepile>.

The portal is a JumboMail "embed dynamic page" with no public API and no login —
you normally fill in a short form (email + case selection) and then drag files into
a browser, or open a `https://fileshare.radware.com/j/<key>` link to fetch what was
sent. These scripts automate both directions so you can send and receive files from
a terminal, a jump host, or a cron job.

| Script | Needs | Use when |
| --- | --- | --- |
| [`fileshare_upload.sh`](fileshare_upload.sh) | `curl`, `python3` | **Default for uploads.** Talks to the portal's private API directly. Fast, no browser. Optionally routes through a proxy via `-x`. |
| [`fileshare_download.sh`](fileshare_download.sh) | `curl`, `python3` | Downloads the file(s) behind a `fileshare.radware.com/j/<key>` link. Optionally routes through a proxy via `-x`. |
| [`upload_to_radware.py`](upload_to_radware.py) | Python + Playwright + Chromium | Fallback if Radware/JumboMail change the API. Drives a real browser through the actual form. |

Both shell scripts connect directly to the internet by default. If the host
running them has no direct internet connection, pass `-x PROXY` (or export
`HTTPS_PROXY`/`https_proxy`) to route every request through an HTTPS/HTTP/SOCKS
proxy — see [Using a proxy](#using-a-proxy).

---

## Quick start (curl version)

```bash
chmod +x fileshare_upload.sh

# No case / new service request
./fileshare_upload.sh -e you@radware.com bigfile.tar.gz

# Attach to an existing service request
./fileshare_upload.sh -e you@radware.com -s 12345678 capture.pcap dump.log

# Through a proxy
./fileshare_upload.sh -x https://proxy.example.com:8443 -e you@radware.com bigfile.tar.gz
```

Output:

```
Uploading 2 file(s), 200009 bytes, as you@radware.com
  uploading capture.pcap (9 bytes)...
  uploading dump.log (200000 bytes)...
Upload complete.
  Transaction ID:    59712608
  Download link:     https://fileshare.radware.com/j/rOPm2piZ9E2IBiU
  Self removal link: https://fileshare.radware.com/j/rOPm2piZ9E2IBiU/delete/5876...
```

Keep the **self removal link** if you may need to withdraw the upload — it is the
only way to delete the transfer afterwards.

### Options

```
Usage: fileshare_upload.sh -e EMAIL [-s SR_NUMBER] [-x PROXY] FILE [FILE...]

  -e EMAIL      Your email address (required by the form).
  -s SR_NUMBER  Existing Service Request number.
                Omit for "No Case / New Service Request".
  -x PROXY      HTTPS proxy to use, e.g. https://proxy.example.com:8443 or
                https://user:pass@proxy.example.com:8443 (also HTTP/SOCKS
                proxy URLs are accepted, per curl's -x/--proxy syntax).
                Defaults to $HTTPS_PROXY / $https_proxy if set. Omit entirely
                to connect directly with no proxy.
```

Multiple files are sent as a single transaction, exactly as if you had added them
all to the browser's upload queue before pressing **Send**.

### Requirements

`curl` and `python3` only — both are present on essentially every Linux box.
`python3` is used purely to build and parse JSON (standard library, no pip
packages). `file(1)` is used to detect MIME types when available.

---

## Browser version (fallback)

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/playwright install chromium

.venv/bin/python upload_to_radware.py --email you@radware.com bigfile.tar.gz
.venv/bin/python upload_to_radware.py --email you@radware.com --sr 12345678 dump.pcap
.venv/bin/python upload_to_radware.py --email you@radware.com --show file.zip
```

| Flag | Meaning |
| --- | --- |
| `--email` | Email address for the form (required). |
| `--sr NUMBER` | Existing Service Request number. |
| `--show` | Run with a visible browser window instead of headless. |
| `--timeout SECONDS` | How long to wait for the transfer to finish (default 3600). |

This version clicks through the real UI: dismisses the cookie banner, fills the
form, presses **Next**, attaches the files to the page's hidden file input,
presses **Send**, and waits for the success text.

---

## Downloading files (`fileshare_download.sh`)

```bash
chmod +x fileshare_download.sh

# Download every file in the share to the current directory
./fileshare_download.sh https://fileshare.radware.com/j/paS8gV6s2k-7zr3

# List the files in a share without downloading
./fileshare_download.sh -l https://fileshare.radware.com/j/paS8gV6s2k-7zr3

# Only fetch one file, into a specific directory
./fileshare_download.sh -o downloads/ -f ComparePlus.zip paS8gV6s2k-7zr3

# Through a proxy
./fileshare_download.sh -x https://proxy.example.com:8443 https://fileshare.radware.com/j/paS8gV6s2k-7zr3
```

A bare share key (the part after `/j/`) works the same as the full URL. If the
share has more than one file and no `-f` is given, all files are fetched together
as a single zip (matching the portal's own **Download** button); a single selected
file is fetched directly, not zipped.

### Options

```
Usage: fileshare_download.sh [-o DIR] [-f FILENAME]... [-x PROXY] [-l] LINK

  LINK          Share link (https://fileshare.radware.com/j/XXXX) or bare key.
  -o DIR        Output directory (default: current directory).
  -f FILENAME   Only download this file (repeatable). Default: all files.
  -x PROXY      HTTPS proxy to use, e.g. https://proxy.example.com:8443 or
                https://user:pass@proxy.example.com:8443 (also HTTP/SOCKS
                proxy URLs are accepted, per curl's -x/--proxy syntax).
                Defaults to $HTTPS_PROXY / $https_proxy if set. Omit entirely
                to connect directly with no proxy.
  -l            List the files in the share and exit (no download).
```

### How it works

| # | Call | Purpose |
| --- | --- | --- |
| 1 | `GET /Mails/RedirectToGallery` | resolves the short `/j/<key>` link to an encrypted mail id |
| 2 | `POST /Mails/ReactGetMailFiles` | lists the files in the transaction (paginated, 30 per page) |
| 3 | `POST /mails/ReactGetDownloadLink` | requests a one-time token URL for the selected file(s) |
| 4 | `GET` the token URL | redirects to a signed CDN URL that serves the actual bytes |

The API requires an XHR-style `Accept: application/json, text/plain, */*` header —
without it, `ReactGetMailFiles` answers `409 Incorrect payload!`. It also caps
`perPage` at 30, so the script pages through the file list instead of requesting
everything in one call.

---

## How the curl version works

The upload flow was reverse-engineered by recording the browser's network traffic
during a real upload. The script reproduces these calls against
`https://api.fileshare.radware.com`:

| # | Call | Purpose |
| --- | --- | --- |
| 1 | `GET /Utils/ReactGetBasicSettings` | S3 access key id used for the upload POST |
| 2 | `GET /EmbedDynamics/GetEmbedDynamicPageForDisplay` | the form id for the Radware page |
| 3 | `POST /Mails/CreateEmbedMailReact` | creates the transaction; carries the email, case choice and SR number. Returns the encrypted mail id and a CSRF token |
| 4 | `POST /Mails/ReactValidateUploadSizeHomePage` | size/quota check, must answer `uploadconfirmed` |
| 5 | `GET /Mails/GetUploadEndpoint` | the destination bucket host |
| 6 | `POST /Mails/SignAWSUrlForFineUploaderJumboForms` | *per file* — the backend signs an S3 POST policy |
| 7 | `POST https://files.fileshare.radware.com/` | *per file* — the actual bytes, as a browser-style S3 multipart POST |
| 8 | `POST /Mails/FileUploadCompleteJumboforms` | *per file* — registers the stored object and its ETag |
| 9 | `POST /Mails/ReactMailUploadCompleteHomePage` | finalises the transaction |
| 10 | `GET /Mails/ReactGetMailShortDetails` | returns the short key used to build the download and self-removal links |

Notes on the implementation:

- The API rejects requests without a matching `Origin`/`Referer`, so every call
  sends them.
- Nothing is hardcoded that can be discovered: the S3 access key id and the form
  id are fetched at runtime. There are no credentials in this repository.
- Step 7 is a standard S3 browser POST. The field order matters — `file` must be
  the last multipart field, and the submitted fields must match the conditions in
  the signed policy exactly.
- Step 5 returns a transient `409` for a short window after step 4, and the upload
  host occasionally returns `500`. Both are retried with a short backoff.

---

## Troubleshooting

**`error: could not resolve upload endpoint`**
Step 5 kept returning 409. Usually transient; re-run. If it persists, the portal
may have changed — try the Playwright version.

**`error: upload of <file> failed (HTTP 500)`**
The upload host is intermittently flaky. The script already retries three times;
re-run if it still fails.

**`error: upload rejected: {"exitCode":"..."}`**
The size or quota check refused the transfer. Check the total size of your files
against the portal's limit.

**`error: 'python3' is required`**
Install `python3` (stdlib only — no pip packages needed for the curl version).

**The API changed and the curl version broke**
Use [`upload_to_radware.py`](upload_to_radware.py), which drives the real UI. To
re-derive the API, open the portal with DevTools, record a small upload, and
compare the XHR calls with the table above.

---

## Using a proxy

Both `fileshare_upload.sh` and `fileshare_download.sh` accept an optional `-x
PROXY` flag that routes every `curl` request (API calls and the S3/CDN file
transfer) through an HTTPS/HTTP/SOCKS proxy. Use it on networks without a
direct internet connection; omit it to connect directly, same as before.

```bash
# Explicit proxy, same arguments as without -x otherwise
./fileshare_upload.sh -x https://proxy.example.com:8443 -e you@radware.com bigfile.tar.gz
./fileshare_download.sh -x https://proxy.example.com:8443 https://fileshare.radware.com/j/paS8gV6s2k-7zr3

# Or rely on the usual environment variables instead of -x
HTTPS_PROXY=https://proxy.example.com:8443 ./fileshare_upload.sh -e you@radware.com bigfile.tar.gz
```

`-x` accepts anything `curl`'s own `-x`/`--proxy` option accepts — `http://`,
`https://` and `socks5://` proxy URLs, with optional `user:password@`
credentials embedded in the URL. When `-x` is omitted, the scripts fall back to
the standard `HTTPS_PROXY`/`https_proxy` environment variables, so they also
behave correctly in shells that already export a proxy, and connect directly
when none is set.

---

## Caveats

- These scripts depend on a **private, undocumented API**. Radware or JumboMail can
  change it at any time without notice.
- Uploads are real submissions. Anything you send is visible to Radware support.
- Uploads expire on the portal's own schedule (the transaction is created with
  `expireAfter: 3`); use the self-removal link to delete earlier.
