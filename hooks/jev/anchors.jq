# anchors.jq — lines in a brief that already name a model tier.
#
# Claudette's briefs carry "Model: sonnet — routine fix" and "jev: opus/opus 0.9 [...]";
# others say "Why opus: ...", "Tier: sonnet", "Chosen model: opus" or "Model (opus): ...".
# A line counts only if it names a tier right after the label, so "jev: route.sh
# returns ..." or "Model: User schema lives in ..." stay. Left in, they anchor
# Jev on the author's guess (and the Agent hook would re-read route.sh's own
# answer), so route.sh drops them before building the state. In the real eval set
# 30% of briefs had such a line, and the blind labeller agreed with it 93% of the
# time (70% where there was none).
def anchor_line:
  test("^\\s*[-*+>]?\\s*[*_]*model( choice| tier)?[*_]*\\s*:[*_]*\\s*[*_]*(haiku|sonnet|opus|fable)\\b"; "i")
  or test("^\\s*[-*+>]?\\s*[*_]*model[*_]*\\s*\\(\\s*(haiku|sonnet|opus|fable)\\s*\\)"; "i")
  or test("^\\s*[-*+>]?\\s*[*_]*jev[*_]*\\s*:\\s*(haiku|sonnet|opus|fable)(/|\\b)"; "i")
  or test("^\\s*[-*+>]?\\s*[*_]*(why|tier|chosen model)[*_]*\\s*[:(]?\\s*[*_]*(haiku|sonnet|opus|fable)\\b"; "i");

# strip_anchors: string -> {text, stripped: <number of lines removed>}
def strip_anchors:
  split("\n") as $l
  | [$l[] | select(anchor_line | not)] as $k
  | {text: ($k | join("\n")), stripped: (($l | length) - ($k | length))};

def anchored: strip_anchors | .stripped > 0;
