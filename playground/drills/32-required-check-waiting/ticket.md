#help-platform

  Priya (payments):  My PR on playground-demo-api ("Document the readiness probe
                     contract", branch priya/readiness-note) is all green but the
                     merge button says "Required statuses must pass before merging"
                     and under it: "build  Expected -- Waiting for status to be
                     reported". It's been 40 minutes. I re-ran the checks twice.
  Priya:             I see "build (3.12)" and "build (3.13)" in the list, both
                     passing. Where's "build"?
  Your lead (DM):    Priya's change has to ship today. Do NOT just switch the
                     protection off, and don't merge it with the admin override
                     -- tell me why it's stuck and fix the rule properly.

  Your clone is in ~/platform-playground-github/playground-demo-api.
