# What would an ECR lifecycle policy do to ONE tag? A reading of the documented
# rules, good enough to judge a fix without waiting for ECR's own (asynchronous,
# up to 24 h) evaluation:
#   - rules are tried in rulePriority order (lowest number first);
#   - an image is acted on by the FIRST rule that selects it, never by a later one;
#   - tagStatus any = every image; untagged = images with no tag; tagged = images
#     with a tag matching tagPrefixList (startswith) or tagPatternList (* wildcard);
#   - countType sinceImagePushed: expire when older than countNumber days;
#   - countType imageCountMoreThan: of the images the rule selects, newest first,
#     keep countNumber and expire the rest.
#
# Input:  {policy: <policy document>, images: [{tags: [...], pushed: <sortable: epoch or ISO-8601>}], target: "<tag>"}
# Output: {fate: missing|untouched|kept|expires, why: "...", keep: <n or null>}
def tore: gsub("(?<c>[^A-Za-z0-9_*-])"; "\\" + .c) | gsub("\\*"; ".*") | "^" + . + "$";

def selects($r; $img):
  $r.selection as $s
  | if $s.tagStatus == "any" then true
    elif $s.tagStatus == "untagged" then ($img.tags | length) == 0
    else
      ($img.tags | length) > 0 and (
        if ($s.tagPatternList // null) != null then
          any($img.tags[]; . as $t | any($s.tagPatternList[]; . as $p | $t | test($p | tore)))
        elif ($s.tagPrefixList // null) != null then
          any($img.tags[]; . as $t | any($s.tagPrefixList[]; . as $p | $t | startswith($p)))
        else false end)
    end;

(.policy.rules | sort_by(.rulePriority)) as $rules
| (.images | to_entries | map(.value + {id: .key})) as $imgs
| .target as $tag
| ($imgs | map(select(.tags | index($tag) != null)) | first // null) as $t
| if $t == null then {fate: "missing", why: "no image carries that tag", keep: null}
  else
    reduce $rules[] as $r ({claimed: [], res: null};
      if .res != null then .
      else
        . as $st
        | ([$imgs[] | select(selects($r; .)) | select(.id as $i | ($st.claimed | index($i)) == null)]
           | sort_by(.pushed) | reverse) as $sel
        | ($sel | map(.id)) as $ids
        | if ($ids | index($t.id)) == null then .claimed += $ids
          elif $r.selection.countType == "sinceImagePushed" then
            .res = {fate: "expires",
                    why: "rule \($r.rulePriority) (\($r.description // "no description")) selects this tag and expires anything pushed more than \($r.selection.countNumber) \($r.selection.countUnit // "day") ago -- it WILL go, however long it has been running",
                    keep: null}
          else
            ($ids | index($t.id) + 1) as $rank
            | if $rank > $r.selection.countNumber then
                .res = {fate: "expires",
                        why: "rule \($r.rulePriority) keeps the newest \($r.selection.countNumber) of the images it selects; this one is number \($rank)",
                        keep: $r.selection.countNumber}
              else
                .res = {fate: "kept",
                        why: "rule \($r.rulePriority) keeps the newest \($r.selection.countNumber) of the images it selects; this one is number \($rank)",
                        keep: $r.selection.countNumber}
              end
          end
      end)
    | .res // {fate: "untouched", why: "no rule selects this tag", keep: null}
  end
