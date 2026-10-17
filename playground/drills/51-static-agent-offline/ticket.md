#help-platform, Monday 08:40

Ines (release eng):  the monthly release has to be signed by 10:00. The job
                     "release-signer" has been queued since 08:15 and says it
                     is waiting for an executor on static-01, which is offline.
                     It only runs on build-01: the signing key lives on that
                     box, nowhere else.
Ines:                I can only see Jenkins, not the machine. The node page just
                     says offline. Somebody suggested running it on the
                     built-in node to get it out of the door. Please don't: the
                     key is not there, and the release manager signs off on
                     WHERE it was signed.

#platform-changes, Saturday

Jordan (platform):   re-imaged build-01 for the disk swap, put it back from our
                     saved provisioning file. Marked the node offline in Jenkins
                     while I worked on it, will re-enable it Monday.

(The static agent is a Docker container started by playground/setup/static-agent.sh;
 the job is in Jenkins at /job/release-signer, its repo is release/release-signer.)
