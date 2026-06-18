# my-cubrid-jira

Personal CUBRID Jira issue notes in Markdown format.

Issue files live in the `issues/` directory, one file per Jira issue, named
`CBRD-<number>[-slug].md`. See [`CLAUDE.md`](CLAUDE.md) for the full workflow.

## Upload to Jira

Use the `upload` just recipe to interactively upload a Markdown file to Jira:

```sh
just upload      # fzf picker → preview → confirm → upload
just --list      # see all recipes (upload-file, fetch, list, doctor, serve, …)
```

`just upload` runs `cubrid-jira-upload-fzf.sh`, which:

1. Lists all `issues/*.md` files in an `fzf` picker with a preview pane.
2. Hands the choice to `cubrid-jira-upload.sh`, which detects the issue key from
   the filename (e.g. `CBRD-25356-some-descriptive-name.md`) or prompts for one.
3. Shows the current Jira issue + a local preview and asks before uploading.
4. Normalizes Korean spacing, then uploads (Markdown → Jira wiki markup).

Credentials (`JIRA_URL`/`JIRA_USER`/`JIRA_PASSWORD`) come from `.envrc` via
direnv. Run `just doctor` to verify tools and credentials.

### Requirements

- [`jira-md-upload`](https://github.com/vimkim/md-to-jira-uploader) — must be installed and configured
- [`fzf`](https://github.com/junegunn/fzf)
- [`bat`](https://github.com/sharkdp/bat) (optional, for syntax-highlighted preview)
- [`just`](https://github.com/casey/just)
