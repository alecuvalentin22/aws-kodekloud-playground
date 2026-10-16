From: Security lead                                           #platform-team

  pentest finding PT-07 (high): a pod in ANY namespace on the CI nodes can
  mint an ECR token and push images to platform-lab/demo-api. they proved it
  with a throwaway pod -- it's still running in namespace `sandbox`, look at
  its logs. I want the Jenkins agent to be the ONLY thing that can push.
  IRSA or Pod Identity, your call. what's the plan, and what's the ETA?

  (If this AWS account will not let you do it, prove that, and write the
   design you WOULD ship: ~/platform-playground-aws/evidence/14-design.md)
