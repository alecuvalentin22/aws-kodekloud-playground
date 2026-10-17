#help-platform, 14:05

Priya (billing):  invoice-gen #1 was green this morning. Then I bumped money-lib
                  to 2.0.0 in deps.lock (the half-cent rounding fix) and removed
                  the legacy template, because it leaks our internal hostname.
                  #2 is red: "money-lib 1.4.0 is older than deps.lock wants
                  (2.0.0)". But deps.lock says 2.0.0! I hit Build Now again:
                  same. It works on my laptop.
Priya:            it has to stay on the static box, the PDF renderer licence is
                  tied to build-01. Please don't move it to a pod.
Sam (payments):   never seen that on our pods, ours just work 🤷
Security (Omar):  once it builds again: confirm the legacy template is really
                  gone from what we ship. It must not be in the release.

(The job is /job/invoice-gen in Jenkins; the repo is billing/invoice-gen, cloned at
 ~/platform-playground/invoice-gen. It builds on the static agent, static-01.)
