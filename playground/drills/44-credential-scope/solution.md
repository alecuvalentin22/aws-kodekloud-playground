ROOT CAUSE
  Credentials are scoped by where they are stored. A job sees the credentials of
  its own folder, its parent folders and the global store; never a sibling
  folder's. artifactory-token used to be global, so every job on the instance
  could use it, risk's fraud-scorer included, and risk had quietly built on it
  for months. Jordan's least-privilege tidy-up moved it into the payments
  folder (the right direction), so only payments' jobs still see it. risk's
  build now dies in `withCredentials` with (verbatim, local playground):
      ERROR: Could not find credentials entry with ID 'artifactory-token'
  The error is not "access denied": from risk's folder the credential does not
  exist. Same ID, different folder, different answer.

FIX
  Give risk its OWN credential, in risk's folder, same ID so the Jenkinsfile
  does not change:
    Jenkins -> risk -> Credentials -> Folder -> Global credentials (unrestricted)
    -> Add Credentials -> Kind "Secret text", ID artifactory-token,
    Secret = the token the Artifactory admins issued to risk.
  Or, the same thing as an API call (admin; this is what the UI posts):
    POST /job/risk/credentials/store/folder/domain/_/createCredentials
  (Folder-scoped credentials come with the Credentials plugin plus
   cloudbees-folder, which this Jenkins has; nothing extra to install.)
  Rebuild risk/fraud-scorer: green. payments is untouched.

NOT the fix
  - Moving it back to global: it works, and it undoes the least-privilege change
    for the whole instance. Any job (any branch of any repo that can add a
    Jenkinsfile) could `withCredentials` it and print it.
  - Pasting payments' secret into risk's folder: one token, two teams. No audit
    trail ("who published this?"), no revoking one team without breaking the
    other, and Artifactory sees payments publishing risk's artifacts. The ticket
    said "it's the token they use, it's fine"; that sentence is the smell.
  - Echoing the secret into the log to check it: withCredentials masks the whole
    secret (and its base64), but a reversed or cut fragment is not masked. A leaked
    secret is a rotation, not a cleanup.

WHAT STOPS IT RECURRING
  - Credentials are defined as code (JCasC `credentials:`, or a folder-level
    block), reviewed like any change, so "moved into payments" shows up as a
    diff someone from risk can see.
  - Before moving a credential: find its users. grep the org's Jenkinsfiles for
    credentialsId: 'artifactory-token', and look at which jobs' builds used it.
    A "nobody uses it" assumption is how Jordan broke risk.
  - One credential per team per target, named the same everywhere; shared,
    read-only things (a pull-only mirror token) can live in a common parent
    folder instead.

SAY THIS IN THE INTERVIEW
  "The message said the credential did not exist, not that it was denied, so I
  compared the two jobs' folders instead of the Jenkinsfile. The token had been
  global and a least-privilege cleanup had moved it into payments' folder;
  risk had been depending on it by accident. I did not put it back in global and
  I did not copy payments' token, because that either hands the secret to every
  job or shares one identity between two teams. risk already had its own token
  from Artifactory, so I created it in risk's folder with the same ID, and the
  pipeline went green without touching its Jenkinsfile. Then I asked that
  credential moves be done as reviewed JCasC changes with a usage check first."
