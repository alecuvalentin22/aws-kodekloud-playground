401 and 403 are different questions. 401 = no credentials ARRIVED at the
registry. 403 / "denied" = they arrived and were refused. Sam checked IAM,
which answers the 403 question. Go back to the build console and read the
Build image stage from its first line, not from the error.
---
Look for a WARNING well above the 401, about loading a config file. Which
container wrote that file, as which user, with which mode? Which user does
BuildKit run as? (resources/podtemplates/build.yaml)
---
Compare buildImage.groovy before and after Jordan's commit
(git -C ~/platform-playground-aws/platform-lib log -p -1). Put the
ownership change back -- or explain a better one -- and rebuild main.
