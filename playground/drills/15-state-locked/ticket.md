From: Priya (payments team)                                  #help-platform

  my terraform apply on the release tracker got killed halfway (laptop slept,
  VPN dropped, I killed the terminal). since then nobody can plan or apply:
  "Error acquiring the state lock". I'm out the rest of the day, sorry.
  it's in ~/platform-playground-aws/tf-lock (creds: . ./aws-env.sh)

From: Dan (payments team)                                    #help-platform

  I can see a .tflock file in the state bucket. can't we just delete it? or
  run with -lock=false, I only need the release out by 5
