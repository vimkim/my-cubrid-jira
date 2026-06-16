serve:
    markserv . --port 8000 --browser false

# Pick an issue with fzf and upload it (upload-fzf.sh hands off to upload.sh).
upload:
    bash upload-fzf.sh

# Upload one issue file directly (key detect, preview, confirm, upload).
upload-file file:
    bash upload.sh {{file}}
