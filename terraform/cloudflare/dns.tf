# Proxied (orange-cloud) record: traffic goes through Cloudflare, origin IP stays hidden.
resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = var.api_hostname
  type    = "A"
  content = var.origin_ip
  proxied = true
  ttl     = 1 # 1 = automatic, required when proxied
  comment = "quote-api origin (managed by Terraform)"
}
