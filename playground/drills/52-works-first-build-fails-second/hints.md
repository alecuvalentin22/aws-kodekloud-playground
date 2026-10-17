Read build #2's console from the top. Which stage fails, and what does the
"Dependencies" stage say it did? Compare with build #1's console. The code in
deps.lock is right and the checkout is right. So what is different between a
first build and a second one on this machine?
   docker exec pg-static-01 ls -la /home/jenkins/agent/workspace/invoice-gen
---
A static agent keeps the workspace between builds: git only updates tracked
files, and vendor/, dist/, build/ are git-ignored, so they survive. The script
treats an existing vendor/money-lib as "up to date" (a cache with no key), so it
kept the 1.4.0 from build #1. A pod would have started empty, which is why
Sam never sees it. And Security's question is the same bug in the OTHER
direction: once the tests pass, Package copies templates/ INTO a dist/ that
still holds last build's legacy.tmpl.
Wiping the workspace by hand (Job -> Workspaces -> Wipe Out) turns #3 green once.
It is not the fix: the next leftover bites again.
---
Make the pipeline start from a known state: cleanWs() (ws-cleanup plugin) or
deleteDir() at the START of the job, before the checkout, so it also protects
a build whose predecessor was aborted or died with the node (a post{} cleanup
never ran there). Also fine: a fresh-checkout option (checkout with the
CleanBeforeCheckout extension, `git clean -fdx` also removes ignored files).
A cleanup at the END as well keeps the box tidy and credentials from lingering.
Declarative has no "before agent" hook, so use skipDefaultCheckout() and wipe,
then `checkout scm`. Keep the label: the job stays on static-01.
