Terraform plans from three things: your config, the state, and (on refresh)
the real world. The bucket is in the real world and in the config -- what is
missing from the third? Run `terraform state list`. And before you touch
anything: is "it's only an export" true? `aws s3api list-object-versions` on the
bucket, and note its creation date -- you will want to prove afterwards that
it is the same bucket.
---
Adopting something that exists is `import`: an `import { to = ...  id = ... }`
block in the config (Terraform >= 1.5; `terraform plan` shows what it will
import), or `terraform import ADDRESS ID` on the command line. There are TWO
resources in main.tf, so two imports. Look up the import ID of each in the AWS
provider docs (the "Import" section at the bottom of the resource page); the
versioning one is not the same kind of ID as you might expect.
---
After the import, `terraform plan` will NOT be clean: the config was written
from memory and disagrees with reality (tags, versioning). Do not apply that
plan -- read it. It would strip tags and suspend versioning on a bucket that
holds the export. The code is what has to change, until plan says "No changes";
then apply (it only records the imports; a Terraform-only attribute such as force_destroy is the one change an import always leaves). Not `ignore_changes`:
that makes the plan clean by hiding the difference.
