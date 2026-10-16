ROOT CAUSE
  Jenkinsfiles from SCM run in the Groovy sandbox. `'git ...'.execute()` is
  Groovy's "run a process", and the sandbox rejects it with
  RejectedAccessException ("Scripts not permitted to use staticMethod ...
  execute java.lang.String"). Code at the top of a Jenkinsfile, outside any
  node/agent, runs ON THE CONTROLLER, not on the agent pod.

WHY NOT APPROVE IT
  Approving the signature allows every pipeline on the instance to run
  arbitrary processes as the Jenkins user on the controller: read
  credentials.xml and secrets, change other jobs. A two-line convenience
  becomes "any developer who can push a branch owns Jenkins". It would also
  not work: the controller has no checkout of the repo.

FIX
  Remove the two lines. Give QA what they asked for in the LIBRARY, which is
  trusted and reviewed, once for every team, e.g. in standardPipeline's Build
  image stage:
      currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"

SAY THIS IN THE INTERVIEW
  "I said no to the approval but yes to the request. The sandbox is the
  boundary between code any developer can push and code that runs with
  Jenkins's own privileges; approving String.execute() erases it for every
  pipeline. The right place for that logic was the shared library, which
  runs trusted because the platform team reviews it -- so QA got the build
  names for all teams, not just one."

  Same topic on EKS: platform-lab drills/18 section 11.
