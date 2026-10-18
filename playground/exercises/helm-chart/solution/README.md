# REFERENCE SOLUTION -- for comparing, not for starting

`chart/notes-api/` is the finished chart for the exercise in `../README.md`, and
`walkthrough.sh` runs steps 5 to 7 with it. Write yours first; then
`diff -ru ~/platform-playground/notes-api/chart/notes-api chart/notes-api`.

* Nothing in the exercise uses this directory by default (`check.sh` judges
  `~/platform-playground/notes-api/chart/notes-api`).
* To see the checks go green with it: `./walkthrough.sh`, then
  `CHART_DIR=$PWD/chart/notes-api ../check.sh`.
