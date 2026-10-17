output "quote_api_record_id" {
  description = "ID of the managed DNS record (use it for future imports)."
  value       = cloudflare_dns_record.quote_api.id
}

output "cache_ruleset_id" {
  description = "ID of the cache ruleset."
  value       = cloudflare_ruleset.quote_api_cache.id
}
