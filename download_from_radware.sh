#!/usr/bin/env bash
# Download files from a Radware Fileshare share link (https://fileshare.radware.com/j/<key>)
# using only curl -- no browser required. python3 is used for JSON handling only.
#
# The portal is a JumboMail "gallery" page. Its private API flow is:
#   1. GET  /Mails/RedirectToGallery       -> resolves the short "/j/<key>" link to an encrypted mail id
#   2. POST /Mails/ReactGetMailFiles       -> the list of files in the transaction
#   3. POST /mails/ReactGetDownloadLink    -> a one-time token URL for the file(s) to fetch
#   4. GET  <token URL>                    -> redirects to a signed CDN URL with the actual bytes
#
# Usage:
#   ./download_from_radware.sh https://fileshare.radware.com/j/paS8gV6s2k-7zr3
#   ./download_from_radware.sh -o downloads/ paS8gV6s2k-7zr3
#   ./download_from_radware.sh -l https://fileshare.radware.com/j/paS8gV6s2k-7zr3
#   ./download_from_radware.sh -f ComparePlus.zip https://fileshare.radware.com/j/paS8gV6s2k-7zr3

set -euo pipefail

API="https://api.fileshare.radware.com"
SITE="https://fileshare.radware.com"

OUTDIR="."
PASSWORD=""
LIST_ONLY=0
declare -a WANT_FILES=()

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [-o DIR] [-p PASSWORD] [-f FILENAME]... [-l] LINK

  LINK          Share link (https://fileshare.radware.com/j/XXXX) or bare key.
  -o DIR        Output directory (default: current directory).
  -p PASSWORD   Password, for password-protected shares.
  -f FILENAME   Only download this file (repeatable). Default: all files.
  -l            List the files in the share and exit (no download).
EOF
    exit 2
}

while getopts ":o:p:f:lh" opt; do
    case "$opt" in
        o) OUTDIR="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        f) WANT_FILES+=("$OPTARG") ;;
        l) LIST_ONLY=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 1 ]] || usage
LINK="$1"

for dep in curl python3; do
    command -v "$dep" >/dev/null || { echo "error: '$dep' is required" >&2; exit 1; }
done

# Accept a bare key or a full share URL; the key is always the last path segment.
KEY="${LINK%%\?*}"
KEY="${KEY%/}"
KEY="${KEY##*/}"
[[ -n "$KEY" ]] || usage

REF="$SITE/j/$KEY"

# The backend rejects requests without a matching Origin/Referer and an XHR-style Accept header.
# A single attempt: prints the body, returns non-zero on a non-2xx status.
api_once() {
    local status tmp rc=0
    tmp=$(mktemp)
    status=$(curl -sS --max-time 60 -o "$tmp" -w '%{http_code}' \
        -H "Origin: $SITE" -H "Referer: $REF" \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) radware-fileshare-downloader' \
        "$@") || status="000"
    cat "$tmp"
    [[ "$status" == 2* ]] || rc=1
    rm -f "$tmp"
    return $rc
}

# The API intermittently answers 409/5xx for requests that succeed on a retry.
# Retried requests must not read a POST body from stdin (it would be consumed by the first attempt).
api() {
    local attempt out
    for attempt in 1 2 3 4 5; do
        if out=$(api_once "$@" 2>/dev/null); then
            printf '%s' "$out"
            return 0
        fi
        sleep $((attempt * 2))
    done
    echo "error: API request failed after $((attempt)) attempts: $(head -c 300 <<<"$out")" >&2
    return 1
}

# POST a JSON body read from a real file, so it survives being retried.
json_api() {
    local body_file="$1"; shift
    api -H 'Content-Type: application/json' --data-binary "@$body_file" "$@"
}

# --- 1. resolve the short link to an encrypted mail id ----------------------
redirect=$(api "$API/Mails/RedirectToGallery?key=$KEY&collectionId=&userId=&encryptedRequestUserEmail=&encryptedRequestSenderEmail=&encryptedDeletedLinkRequest=&encryptedContributorEmail=")
gallery_url=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "$redirect" 2>/dev/null || true)
[[ "$gallery_url" == */gallery/* ]] || { echo "error: link not found or expired: $LINK" >&2; exit 1; }
mail_id="${gallery_url##*/gallery/}"
mail_id="${mail_id%%\?*}"
[[ -n "$mail_id" ]] || { echo "error: could not resolve mail id from: $gallery_url" >&2; exit 1; }

# The rest of the calls are made from the gallery page, not the short link.
REF="$gallery_url"

# --- 2. list the files in the transaction (the API caps perPage at 30) ------
declare -a entries=()
page=1
while :; do
    body_file=$(mktemp)
    PASS="$PASSWORD" MID="$mail_id" PAGE="$page" python3 -c '
import json, os
pw = os.environ["PASS"] or None
print(json.dumps({"encryptedMailId": os.environ["MID"], "page": int(os.environ["PAGE"]), "perPage": 30,
                  "sortAsc": True, "sortBy": "Name", "folderId": None, "password": pw,
                  "search": "", "deleteHashId": "", "contributorsFilter": [],
                  "foldersStructured": False}))
' > "$body_file"
    files_body=$(json_api "$body_file" -X POST "$API/Mails/ReactGetMailFiles")
    rm -f "$body_file"

    mapfile -t page_entries < <(FJ="$files_body" python3 -c '
import json, os
d = json.loads(os.environ["FJ"])
for fid, meta in (d.get("files") or {}).items():
    print(fid + "\t" + meta["Name"] + "\t" + str(meta["Size"]))
' 2>/dev/null || true)

    [[ ${#page_entries[@]} -gt 0 ]] || break
    entries+=("${page_entries[@]}")
    [[ ${#page_entries[@]} -eq 30 ]] || break
    page=$((page + 1))
done

[[ ${#entries[@]} -gt 0 ]] || { echo "error: no files found (wrong link or password?): $files_body" >&2; exit 1; }

echo "Found ${#entries[@]} file(s) in $LINK"
for e in "${entries[@]}"; do
    IFS=$'\t' read -r _ name size <<<"$e"
    printf '  %-40s %10d bytes\n' "$name" "$size"
done

[[ "$LIST_ONLY" -eq 0 ]] || exit 0

# --- 3. pick which files to fetch -------------------------------------------
declare -a ids=()
if [[ ${#WANT_FILES[@]} -gt 0 ]]; then
    for want in "${WANT_FILES[@]}"; do
        found=0
        for e in "${entries[@]}"; do
            IFS=$'\t' read -r fid name _ <<<"$e"
            if [[ "$name" == "$want" ]]; then ids+=("$fid"); found=1; break; fi
        done
        [[ "$found" -eq 1 ]] || { echo "error: file not found in share: $want" >&2; exit 1; }
    done
else
    for e in "${entries[@]}"; do
        IFS=$'\t' read -r fid _ _ <<<"$e"
        ids+=("$fid")
    done
fi

# --- 4. request the download link and fetch the bytes -----------------------
mkdir -p "$OUTDIR"

if [[ ${#ids[@]} -eq 1 ]]; then
    file_list="${ids[0]}"
    download_type="file"
elif [[ ${#WANT_FILES[@]} -eq 0 ]]; then
    file_list=""
    download_type="zip"
else
    file_list=$(IFS=,; echo "${ids[*]}")
    download_type="zip"
fi

body_file=$(mktemp)
PASS="$PASSWORD" MID="$mail_id" FL="$file_list" DT="$download_type" python3 -c '
import json, os
pw = os.environ["PASS"] or None
print(json.dumps({"folderPathId": None, "encryptedMailId": os.environ["MID"],
                  "fileList": os.environ["FL"], "downloadType": os.environ["DT"],
                  "password": pw, "isCollection": False, "culture": "en",
                  "isProxySuccess": True, "uid": None, "captchaServiceName": "google"}))
' > "$body_file"
link_resp=$(json_api "$body_file" -X POST "$API/mails/ReactGetDownloadLink")
rm -f "$body_file"

token_url=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "$link_resp" 2>/dev/null || true)
[[ "$token_url" == http* ]] || { echo "error: could not get a download link: $link_resp" >&2; exit 1; }

echo "Downloading to $OUTDIR ..."
(cd "$OUTDIR" && curl -sS -L -J -O --max-time 3600 \
    -H "Origin: $SITE" -H "Referer: $REF" \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) radware-fileshare-downloader' \
    "$token_url")

echo "Download complete."
