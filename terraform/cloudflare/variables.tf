variable "zone_id" {
  description = "Cloudflare zone ID for example.com."
  type        = string
}

variable "api_hostname" {
  description = "Public hostname of the quote API."
  type        = string
  default     = "quote-api.example.com"
}

variable "origin_ip" {
  description = "Origin IPv4 address behind the proxy (the ingress host)."
  type        = string
  default     = "192.0.2.10" # TEST-NET-1 placeholder; override per environment.
}

variable "existing_dns_record_id" {
  description = "ID of the manually-created DNS record to adopt into Terraform."
  type        = string
}
