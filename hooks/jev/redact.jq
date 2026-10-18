# redact.jq — `include "redact";` then `redact` on a string.
# Scrubs secrets and personal data from text before it is sent to Jev. Paths,
# hostnames and URLs (minus credentials and signed query values) are kept on
# purpose: they are the facts worth preserving. Order matters: URL credentials
# go before the email pattern, key=value before the generic key-ish rule.
def redact:
  # PEM private keys
  gsub("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"; "<private-key>")
  # credentials in URLs: scheme://user:pass@host
  | gsub("(?<s>[a-zA-Z][a-zA-Z0-9+.-]*://)[^/\\s:@\"'<>]+:[^/\\s@\"'<>]+@"; "\(.s)<redacted>@")
  # signed or token query parameters (presigned URLs, OAuth codes)
  | gsub("(?<k>[?&](?i:token|access_token|refresh_token|id_token|api_key|apikey|key|sig|signature|code|password|secret|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential)=)[^&\\s\"'<>]+"; "\(.k)<redacted>")
  # Authorization / Proxy-Authorization headers, any scheme
  | gsub("(?<h>(?i:(proxy-)?authorization)[\"']?\\s*[:=]\\s*[\"']?)(?i:(bearer|basic|token|digest)\\s+)?[^\\s\"',;]+"; "\(.h)<redacted>")
  # bare bearer tokens
  | gsub("(?<b>(?i:bearer)\\s+)[A-Za-z0-9._~+/=-]{8,}"; "\(.b)<redacted>")
  # well-known token formats
  | gsub("\\bsk-(?:ant-|proj-|live_|test_)?[A-Za-z0-9_-]{16,}"; "<secret>")
  | gsub("\\b(?:apik|apikey_)[A-Za-z0-9_-]{16,}"; "<secret>")
  | gsub("\\bgh[pousr]_[A-Za-z0-9]{20,}"; "<secret>")
  | gsub("\\bgithub_pat_[A-Za-z0-9_]{20,}"; "<secret>")
  | gsub("\\bglpat-[A-Za-z0-9_-]{16,}"; "<secret>")
  | gsub("\\bxox[abposr]-[A-Za-z0-9-]{10,}"; "<secret>")
  | gsub("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"; "<secret>")
  | gsub("\\bAIza[0-9A-Za-z_-]{35}\\b"; "<secret>")
  | gsub("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"; "<jwt>")
  # env-style assignments whose name says secret: FOO_TOKEN=..., export DB_PASSWORD="..."
  | gsub("(?<k>\\b(?:[A-Za-z_][A-Za-z0-9_]*)?(?i:key|token|secret|password|passwd|pwd|credentials?)[A-Za-z0-9_]*[\"']?\\s*[:=]\\s*)(?!\\d{1,9}\\b)(?:\"[^\"\\n]*\"|'[^'\\n]*'|[^\\s\"',;}]+)"; "\(.k)<redacted>")
  # long hex/base64 runs shortly after a key-ish word ("api key: 3f9a…", "secret is AbC…")
  | gsub("(?<k>(?i:key|token|secret|password|signature|credential)[^\\n]{0,24}?)(?:[A-Fa-f0-9]{32,}|[A-Za-z0-9+/_-]{32,}={0,2})"; "\(.k)<redacted>")
  # email addresses (git@host:org/repo remotes are kept)
  | gsub("(?<![A-Za-z0-9._%+-])(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"; "<email>")
  # IPv4 addresses
  | gsub("(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9.])"; "<ip>");

# redact_all: every string value in a JSON document (object keys are kept).
def redact_all: walk(if type == "string" then redact else . end);
