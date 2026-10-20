#!/usr/bin/env bash
# Upload files to the Radware Fileshare portal (https://fileshare.radware.com/en/page/radware-filepile)
# using only curl -- no browser required. python3 is used for JSON handling only.
#
# This is a copy of upload_to_radware.sh with support for routing all traffic
# through an HTTPS (or HTTP/SOCKS) proxy, for use from networks where a direct
# internet connection isn't available. See upload_to_radware.sh for the full
# description of the API flow.
#
# Usage:
#   ./fileshare_upload.sh -x https://proxy.example.com:8443 -e you@example.com file1.pcap file2.zip
#   ./fileshare_upload.sh -x https://user:pass@proxy.example.com:8443 -e you@example.com -s 12345678 dump.tar.gz
#   HTTPS_PROXY=https://proxy.example.com:8443 ./fileshare_upload.sh -e you@example.com dump.tar.gz

set -euo pipefail

API="https://api.fileshare.radware.com"
SITE="https://fileshare.radware.com"
PAGE="radware-filepile"
PAGE_URL="$SITE/en/page/$PAGE"

# Ensures temp files are removed even on error exit or Ctrl-C, not just the happy path.
declare -a TMP_FILES=()
cleanup_tmp_files() { rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup_tmp_files EXIT

EMAIL=""
SR=""
# Falls back to the standard HTTPS_PROXY/https_proxy environment variables when
# -x isn't given, so the script also works unchanged in proxy-aware shells.
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") -e EMAIL [-s SR_NUMBER] [-x PROXY] FILE [FILE...]

  -e EMAIL      Your email address (required by the form).
  -s SR_NUMBER  Existing Service Request number.
                Omit for "No Case / New Service Request".
  -x PROXY      HTTPS proxy to use, e.g. https://proxy.example.com:8443 or
                https://user:pass@proxy.example.com:8443 (also HTTP/SOCKS
                proxy URLs are accepted, per curl's -x/--proxy syntax).
                Defaults to \$HTTPS_PROXY / \$https_proxy if set.
EOF
    exit 2
}

while getopts ":e:s:x:h" opt; do
    case "$opt" in
        e) EMAIL="$OPTARG" ;;
        s) SR="$OPTARG" ;;
        x) PROXY="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$EMAIL" && $# -gt 0 ]] || usage
for dep in curl python3; do
    command -v "$dep" >/dev/null || { echo "error: '$dep' is required" >&2; exit 1; }
done
for f in "$@"; do
    [[ -f "$f" ]] || { echo "error: not a file: $f" >&2; exit 1; }
done

# curl's proxy options, applied to every request below; empty when no proxy is set.
declare -a PROXY_OPTS=()
[[ -z "$PROXY" ]] || PROXY_OPTS=(--proxy "$PROXY")

# Read a value out of a JSON document on stdin; each argument is a key or list index.
jget() {
    python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    if d is None:
        break
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print("" if d is None else d)
' "$@"
}

# The backend rejects API requests without a matching Origin/Referer.
# A single attempt: prints the body, returns non-zero on a non-2xx status.
api_once() {
    local status tmp rc=0
    tmp=$(mktemp)
    TMP_FILES+=("$tmp")
    status=$(curl -sS --max-time 60 -o "$tmp" -w '%{http_code}' \
        "${PROXY_OPTS[@]}" \
        -H "Origin: $SITE" -H "Referer: $PAGE_URL" \
        -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) radware-fileshare-uploader' \
        "$@") || status="000"
    cat "$tmp"
    [[ "$status" == 2* ]] || rc=1
    rm -f "$tmp"
    return $rc
}

# The API intermittently answers 409/5xx for requests that succeed on a retry.
# Only use this for calls that are safe to repeat.
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

json_api() { api -H 'Content-Type: application/json' "$@"; }

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

mime_type() {
    local t
    t=$(file --mime-type -b "$1" 2>/dev/null || true)
    echo "${t:-application/octet-stream}"
}

new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

files=("$@")
total_size=0
for f in "${files[@]}"; do total_size=$((total_size + $(file_size "$f"))); done

echo "Uploading ${#files[@]} file(s), $total_size bytes, as $EMAIL"

# --- 1. S3 access key id used for the browser-style POST upload -------------
s3_key=$(api "$API/Utils/ReactGetBasicSettings" | jget s3Key)
[[ -n "$s3_key" ]] || { echo "error: could not read s3Key" >&2; exit 1; }

# --- 2. form id for this embed page ----------------------------------------
form_id=$(api "$API/EmbedDynamics/GetEmbedDynamicPageForDisplay?userName=$PAGE" \
    | jget EmbedDynamicPageFormList 0 EmbedPageFormId)
[[ -n "$form_id" ]] || { echo "error: could not read form id" >&2; exit 1; }

# --- 3. create the transaction with the form answers ------------------------
if [[ -n "$SR" ]]; then choice="Existing Service Request"; else choice="No Case / New Service Request"; fi

create=$(EMAIL="$EMAIL" CHOICE="$choice" SR="$SR" FORM_ID="$form_id" python3 -c '
import json, os
leads = [
    {"Lead_Dynamic_Field_Order": 0, "Lead_Dynamic_Field_Type": "email",
     "Lead_Dynamic_Field_Validation": "required", "Lead_Dynamic_Field_Name": "Email",
     "Lead_Dynamic_Field_Value": os.environ["EMAIL"]},
    {"Lead_Dynamic_Field_Order": 1, "Lead_Dynamic_Field_Type": "radiolist",
     "Lead_Dynamic_Field_Validation": "required", "Lead_Dynamic_Field_Name": "Single Choice",
     "Lead_Dynamic_Field_Value": os.environ["CHOICE"]},
    {"Lead_Dynamic_Field_Order": 2, "Lead_Dynamic_Field_Type": "text",
     "Lead_Dynamic_Download_Name": True, "Lead_Dynamic_Include_In_Email_Subject": True,
     "Lead_Dynamic_Is_Subject": True, "Lead_Dynamic_Is_Visible_For_Inbox": True,
     "Lead_Dynamic_Field_Name": "Service Request Number",
     "Lead_Dynamic_Field_Value": os.environ["SR"]},
]
print(json.dumps({"EmbedUserId": "", "EmbedDynamicFormId": int(os.environ["FORM_ID"]),
                  "EmbedDynamicLeadsJson": json.dumps(leads), "EmbedExternalTransactionId": "",
                  "EmbedSessionId": "", "captchaServiceName": "google"}))
' | json_api -X POST "$API/Mails/CreateEmbedMailReact" --data-binary @-)

mail_id=$(jget MailSid <<<"$create")
[[ -n "$mail_id" ]] || { echo "error: transaction not created: $create" >&2; exit 1; }

# --- 4. quota / size check --------------------------------------------------
check=$(N="${#files[@]}" SIZE="$total_size" MID="$mail_id" python3 -c '
import json, os
print(json.dumps({"culture": "en-US", "filesCount": int(os.environ["N"]),
                  "filesTotalSize": int(os.environ["SIZE"]),
                  "encryptedMailID": os.environ["MID"], "runtime": "FU", "code": None,
                  "uploadFormatsList": None, "server": "up", "expireAfter": 3}))
' | json_api -X POST "$API/Mails/ReactValidateUploadSizeHomePage" --data-binary @-)

[[ "$(jget exitCode <<<"$check")" == "uploadconfirmed" ]] \
    || { echo "error: upload rejected: $check" >&2; exit 1; }

# --- 5. destination bucket --------------------------------------------------
bucket=$(api "$API/Mails/GetUploadEndpoint?realEndpoint=true&encryptedMailId=$mail_id&embedPageEncryptedUserId=&isCollection=false" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin))')
[[ -n "$bucket" ]] || { echo "error: could not resolve upload endpoint" >&2; exit 1; }

names=()
for path in "${files[@]}"; do
    name=$(basename "$path")
    size=$(file_size "$path")
    ctype=$(mime_type "$path")
    uuid=$(new_uuid)
    ext="${name##*.}"
    if [[ "$ext" == "$name" ]]; then key="embed/$mail_id/$uuid"; else key="embed/$mail_id/$uuid.$ext"; fi
    expiration=$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -v+30M +%Y-%m-%dT%H:%M:%S.000Z)

    # --- 6. have the backend sign an S3 POST policy for this object ---------
    signed=$(EXP="$expiration" BUCKET="$bucket" CT="$ctype" KEY="$key" SIZE="$size" NAME="$name" python3 -c '
import json, os
e = os.environ
print(json.dumps({"expiration": e["EXP"], "conditions": [
    {"acl": "private"}, {"bucket": e["BUCKET"]}, {"Content-Type": e["CT"]},
    {"success_action_status": "200"}, {"key": e["KEY"]},
    {"x-amz-meta-addwatermarktothumbnail": "false"},
    {"x-amz-meta-addvideowatermark": "false"},
    {"x-amz-meta-imageratio": "1"},
    {"x-amz-meta-size": e["SIZE"]},
    {"x-amz-meta-folderid": "undefined"},
    {"x-amz-meta-isembed": "true"},
    {"x-amz-meta-qqfilename": e["NAME"]}]}))
' | json_api -X POST "$API/Mails/SignAWSUrlForFineUploaderJumboForms?encryptedMailId=$mail_id" --data-binary @-)

    policy=$(jget policy <<<"$signed")
    signature=$(jget signature <<<"$signed")
    [[ -n "$policy" ]] || { echo "error: signing failed: $signed" >&2; exit 1; }

    # --- 7. the actual upload (S3 browser POST; 'file' must come last) ------
    echo "  uploading $name ($size bytes)..."
    headers=$(mktemp)
    body=$(mktemp)
    TMP_FILES+=("$headers" "$body")
    status=""
    for attempt in 1 2 3; do
        status=$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
            "${PROXY_OPTS[@]}" \
            --max-time 3600 \
            -H "Origin: $SITE" -H "Referer: $PAGE_URL" \
            -F "key=$key" \
            -F "AWSAccessKeyId=$s3_key" \
            -F "acl=private" \
            -F "policy=$policy" \
            -F "signature=$signature" \
            -F "Content-Type=$ctype" \
            -F "success_action_status=200" \
            -F "x-amz-meta-addwatermarktothumbnail=false" \
            -F "x-amz-meta-addvideowatermark=false" \
            -F "x-amz-meta-imageratio=1" \
            -F "x-amz-meta-size=$size" \
            -F "x-amz-meta-folderid=undefined" \
            -F "x-amz-meta-isembed=true" \
            -F "x-amz-meta-qqfilename=$name" \
            -F "file=@$path;type=$ctype" \
            "https://$bucket/") || status="000"
        [[ "$status" == "200" || "$status" == "204" ]] && break
        echo "  attempt $attempt failed (HTTP $status), retrying..." >&2
        sleep 3
    done
    if [[ "$status" != "200" && "$status" != "204" ]]; then
        echo "error: upload of $name failed (HTTP $status)" >&2
        head -c 2000 "$body" >&2; echo >&2
        exit 1
    fi

    etag=$(grep -i '^etag:' "$headers" | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//')
    rm -f "$headers" "$body"

    # --- 8. tell the backend the object landed ------------------------------
    api -X POST "$API/Mails/FileUploadCompleteJumboforms?encryptedMailId=$mail_id" \
        --data-urlencode "key=$key" \
        --data-urlencode "uuid=embed/$mail_id/$uuid" \
        --data-urlencode "name=$name" \
        --data-urlencode "bucket=$bucket" \
        --data-urlencode "etag=$etag" \
        --data-urlencode "addwatermarktothumbnail=false" \
        --data-urlencode "addvideowatermark=false" \
        --data-urlencode "imageratio=1" \
        --data-urlencode "size=$size" \
        --data-urlencode "folderid=undefined" \
        --data-urlencode "isembed=true" >/dev/null

    names+=("$name")
done

# --- 9. finalise ------------------------------------------------------------
# The CSRF token is single-use, so each attempt takes a freshly issued one and
# the transaction status is the real source of truth.
upload_status() {
    api "$API/Mails/ReactGetUploadInfo?encryptedMailId=$mail_id" | jget status
}

finalised=0
for attempt in 1 2 3 4 5; do
    csrf=$(api "$API/Mails/ReactGetUploadInfo?encryptedMailId=$mail_id" | jget csrf)

    done_resp=$(SIZE="$total_size" MID="$mail_id" CSRF="$csrf" python3 -c '
import json, os, sys
names = sys.argv[1:]
e = os.environ
print(json.dumps({"culture": "en-US", "filesTotalSize": int(e["SIZE"]),
                  "encryptedMailID": e["MID"], "runtime": "FU", "CSRFToken": e["CSRF"],
                  "new_uploader": True, "reuploadUserSenderEmail": None,
                  "reUploadFileCount": len(names), "reUploadFilesNames": names,
                  "reuploadComment": False}))
' "${names[@]}" | api_once -H 'Content-Type: application/json' \
        -X POST "$API/Mails/ReactMailUploadCompleteHomePage" --data-binary @- || true)

    if [[ "$(jget exitCode <<<"$done_resp" 2>/dev/null)" == "ok" ]] || [[ "$(upload_status)" == "SENT" ]]; then
        finalised=1
        break
    fi
    sleep $((attempt * 2))
done

[[ "$finalised" == 1 ]] \
    || { echo "error: finalisation failed: $done_resp" >&2; exit 1; }

# --- 10. links --------------------------------------------------------------
details=$(api "$API/Mails/ReactGetMailShortDetails?encryptMailId=$mail_id")
short=$(jget SentMail_Short_Key <<<"$details")
del=$(jget SentMail_Encrypted_DeleteLink <<<"$details")

echo "Upload complete."
echo "  Transaction ID:    $(jget SentMail_Upload_Session_BigIntID <<<"$details")"
echo "  Download link:     $SITE/j/$short"
echo "  Self removal link: $SITE/j/$short/delete/$del"
