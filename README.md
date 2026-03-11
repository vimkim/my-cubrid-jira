# my-cubrid-jira

Personal CUBRID Jira issue notes in Markdown format.

Issue files live in the `issues/` directory. Templates (`issue-template.md`, `pr-template.md`) stay in the root.

## Upload to Jira

Use the `upload` just recipe to interactively upload a Markdown file to Jira:

```sh
just upload
```

This runs `upload.sh`, which:

1. Lists all `.md` files in the directory (excluding templates)
2. Opens an interactive `fzf` picker with a preview pane
3. Detects the Jira issue key from the filename (e.g. `CBRD-25356-some-descriptive-name.md`) or prompts you to enter one.
4. Confirms before uploading

### Requirements

- [`jira-md-upload`](https://github.com/vimkim/md-to-jira-uploader) — must be installed and configured
- [`fzf`](https://github.com/junegunn/fzf)
- [`bat`](https://github.com/sharkdp/bat) (optional, for syntax-highlighted preview)
- [`just`](https://github.com/casey/just)
