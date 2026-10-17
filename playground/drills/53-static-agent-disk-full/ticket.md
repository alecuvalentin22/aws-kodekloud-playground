#help-platform, 16:20

Marta (finance):   the nightly ledger-export went red this afternoon with
                   "No space left on device". I re-ran it and now it just sits
                   there: "static-01 is offline". The month-end close is tonight
                   and the export has to run on build-01 (the finance VPN route
                   is only there).
Omar (security):   Jenkins has been mailing "disk-space: low on static-01" for a
                   couple of weeks. Nobody read it. Don't just silence it.

#platform-changes, three weeks ago

Jordan (platform): build-01 came back from the disk swap with a SMALL workspace
                   volume (96 MB, the big one is on order). All job workspaces
                   live on it. It was fine for the other jobs.

(The job is /job/ledger-export in Jenkins; the repo is finance/ledger-export,
 cloned at ~/platform-playground/ledger-export. The agent is the Docker container
 pg-static-01; its workspace root is /home/jenkins/agent.)
