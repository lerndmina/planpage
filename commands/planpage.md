---
description: Publish a plan, report, or doc as a styled HTML page on your Zipline instance
---

Use the planpage skill (read `${CLAUDE_PLUGIN_ROOT}/skills/planpage/SKILL.md` if it is not already loaded) to publish an HTML page and return the link.

What to publish, in order of preference:

1. If `$ARGUMENTS` names a file, subcommand (`list`, `unpublish <slug>`, `index`), or topic — act on that.
2. Otherwise, if there is a plan or substantial analysis in the current conversation, turn it into a page and publish it.
3. Otherwise, ask what to publish.

$ARGUMENTS
