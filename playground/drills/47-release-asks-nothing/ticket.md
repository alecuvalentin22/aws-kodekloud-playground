From: Sam (payments team)                                     #help-platform

  I released demo-api 1.4.2 to prod with the payments-release job. Same as
  always: open the job, pick prod, type 1.4.2 in the tag box, press Build.
  It went green in five seconds, and the console says it released "latest" to
  STAGING. So prod still runs 1.4.1, and an unknown build is now on staging.
  It never asked me anything it didn't already ask last month.
  What did I do wrong?

From: Priya (payments team)                                   #platform-changes, Tuesday

  tidied the release job's parameters to match what the Slack release bot
  sends: ENV -> TARGET_ENV, TAG -> IMAGE_TAG, plus a DRY_RUN checkbox.
  Merged to main. The bot and the runbook use the new names from now on.

  (Your workspace has the job's repo: ~/platform-playground/release-job.)
