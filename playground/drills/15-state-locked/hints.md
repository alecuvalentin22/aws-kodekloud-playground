Run `terraform plan` in the directory and read the whole error, not the last
line. A lock is a claim that somebody is applying right now. The error says
who, since when, what operation, and gives an ID. What do you have to know
before you are allowed to release somebody else's claim -- and how do you
find that out? (Terraform cannot tell you. People and CI can.)
---
Where does the lock live? With the S3 backend and `use_lockfile`, it is an
object next to the state: s3://<state bucket>/<state key>.tflock (older setups
used a DynamoDB table). Terraform has a supported way to release it that
checks the ID, so you cannot release the wrong one. `terraform force-unlock -help`.
What the supported way is NOT: -lock=false (two writers, one state), deleting
the state object, or deleting the lock object by hand.
---
After the unlock, run `terraform plan` again. It will not say "no changes":
Priya's change never reached the state. Read what it wants to do before you
apply it (or decide it should not go out and revert it), then plan until it is
clean. Whatever you do, the state you end with must be the same state, not a new one.
