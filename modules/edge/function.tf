locals {
  signin_script = "var t=(location.hash.match(/token=([^&]+)/)||[])[1];if(t){localStorage.setItem(${jsonencode(var.token_key)},decodeURIComponent(t));location.replace('/status');}else{document.getElementById('m').textContent='Message the bot with: status';}"

  signin_html = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Sign in</title></head><body><p id=\"m\">Signing in...</p><script>${local.signin_script}</script></body></html>"

  # The inline script is allowed by hash and nothing else loads.
  signin_csp = "default-src 'none'; script-src 'sha256-${base64sha256(local.signin_script)}'"
}

# The default behavior answers every request itself, so nothing outside the
# status behaviors ever reaches an origin: the apex redirects to the page,
# /signin stores the token the bot's status command hands out, and any other
# path is a 404.
resource "aws_cloudfront_function" "edge" {
  name    = "naju-edge"
  runtime = "cloudfront-js-2.0"
  comment = "Apex redirect, sign-in page and 404 for everything else"
  publish = true
  code = templatefile("${path.module}/edge.js.tftpl", {
    signin_html = local.signin_html
    signin_csp  = local.signin_csp
  })
}
