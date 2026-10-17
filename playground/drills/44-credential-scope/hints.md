The message is exact: no credential with that ID is visible FROM THIS JOB.
Credentials have a scope. Compare the two jobs that run the same step:
Jenkins -> payments -> Credentials, Jenkins -> risk -> Credentials, and
Manage Jenkins -> Credentials. Where does 'artifactory-token' live, and who can see it?
---
A job sees the credentials of its own folder, of its parent folders and of the
global store; never those of a sibling folder. Jordan's move was the right
direction (a deploy token for one team should not be visible to every job on the
instance), but it exposed that risk had been quietly using payments' token.
The two shortcuts are the two wrong answers: put it back in global, or paste
payments' secret into risk. Priya already told you where risk's own token is.
---
Create a "Secret text" credential with ID artifactory-token in the RISK folder's
own store: Jenkins -> risk -> Credentials -> Folder -> Global credentials
(unrestricted) -> Add Credentials. The value is in Priya's file; do not cat it
into a build log to "check" it (withCredentials masks the whole secret, but a
reversed or cut piece of it is not masked). Then re-run risk/fraud-scorer, and leave payments alone.
