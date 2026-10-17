Run `terraform plan` and read every line, not the summary. Terraform's job is
to make reality match the code. A "-" on something nobody in the team wrote means
reality has something the code does not. Who put it there, and when?
`terraform plan -refresh-only` shows only what changed outside Terraform, without
proposing to do anything about it.
---
Terraform cannot tell you who. CloudTrail can: `aws cloudtrail lookup-events
--lookup-attributes AttributeKey=EventName,AttributeValue=AuthorizeSecurityGroupIngress`
(events show up after a few minutes, sometimes up to 15). Then judge each drifted item on its own:
what does the rule allow, to whom, on which port? Is the tag change harmful?
"Apply" and "don't apply" are not the only answers: each change can be reverted
(let Terraform do it) or accepted (write it into the code), deliberately.
---
Wrong tools: `lifecycle { ignore_changes }` (hides the drift forever, the next
change in the same place goes unseen), `terraform import` (adopts a resource that
exists but is not in the state; the rule is part of a resource that is), and
writing the unknown rule into main.tf "so the plan is clean" (a clean plan is not
the goal; a safe infrastructure is). Finish with Dan's change applied and
`terraform plan` saying "No changes".
