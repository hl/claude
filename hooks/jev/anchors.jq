# anchors.jq — lines in a brief that already name a model tier.
#
# Claudette's briefs carry "Model: sonnet — routine fix" and "jev: opus/opus 0.9 [...]";
# other briefs say "— opus because ..." or "model haiku — ...". Left in, they anchor
# Jev on the author's guess (and the Agent hook would re-read route.sh's own
# answer), so route.sh drops them before building the state. In the real eval set
# 30% of briefs had such a line, and the blind labeller agreed with it 93% of the
# time (70% where there was none).
def anchor_line:
  test("^\\s*[*_]*\\s*model( choice| tier)?\\s*[*_]*\\s*:"; "i")
  or test("^\\s*[*_]*\\s*jev\\s*[*_]*\\s*:"; "i")
  or test("(—|–|--| - )\\s*[*_]*(haiku|sonnet|opus|fable)[*_]*\\b.{0,80}\\bbecause\\b"; "i")
  or test("\\bmodel\\s*[*_]*\\s*(haiku|sonnet|opus|fable)\\b[*_]*\\s*(—|–|--| - |:|\\()"; "i");

# strip_anchors: string -> {text, stripped: <number of lines removed>}
def strip_anchors:
  split("\n") as $l
  | [$l[] | select(anchor_line | not)] as $k
  | {text: ($k | join("\n")), stripped: (($l | length) - ($k | length))};

def anchored: strip_anchors | .stripped > 0;
